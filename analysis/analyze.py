"""
Análise dos resultados de carga (k6) para o TCC.

Lê os arquivos results/<alvo>/<timestamp>/<cenario>[-repNN]-raw.json, monta uma
tabela por requisição e produz:
  - tables/per_rep.csv ......... métricas por repetição (base do tratamento estatístico)
  - tables/summary.csv ......... média ± IC95% por (arquitetura, cenário)
  - tables/stats_tests.txt ..... Shapiro-Wilk + Kruskal-Wallis + Mann-Whitney (unidade: repetição)
  - tables/useful_throughput.csv ..... vazão descontadas as fichas que voltaram vazias
  - tables/normalized_efficiency.csv . requisições por vCPU-segundo consumida (§3.4)
  - tables/lambda_consumption.csv .... consumo faturado do Lambda por função
  - tables/first_rep_sensitivity.csv . robustez: efeito da primeira repetição
  - figures/*.png .............. gráficos comparativos

Uso:
  python analysis/analyze.py [results_dir] [output_dir]
"""
import json, glob, os, re, sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy import stats

RESULTS = sys.argv[1] if len(sys.argv) > 1 else "results"
OUT = sys.argv[2] if len(sys.argv) > 2 else "analysis"
FIG, TAB = os.path.join(OUT, "figures"), os.path.join(OUT, "tables")
os.makedirs(FIG, exist_ok=True)
os.makedirs(TAB, exist_ok=True)

LABEL = {
    "mono": "Monolito", "micro": "Microsserviços", "serverless": "Serverless",
    # subcenários serverless (decisão 2 / §3.3.3): aparecem como séries próprias
    "serverless-cold": "Serverless (sem otim.)", "serverless-snap": "Serverless (SnapStart)",
}
SCN = ["constant", "ramp", "spike"]
SCNLAB = {"constant": "Constante", "ramp": "Rampa", "spike": "Pico"}
TARGET_ORDER = ["mono", "micro", "serverless", "serverless-cold", "serverless-snap"]
METRICS = ["throughput_rps", "error_rate_pct", "mean_ms", "median_ms", "p95_ms", "p99_ms"]

# Cor fixa por arquitetura: o ciclo padrão do matplotlib reatribui cores quando um
# alvo falta em alguma figura, e a mesma arquitetura mudaria de cor entre elas.
COLOR = {"mono": "tab:blue", "micro": "tab:orange", "serverless": "tab:green",
         "serverless-cold": "tab:green", "serverless-snap": "tab:purple"}

OPORDER = ["listOwners", "ownerDetail", "createVisit", "listVets", "listPetTypes", "createOwner"]
OPLAB = {"listOwners": "Listagem", "ownerDetail": "Ficha agregada", "createVisit": "Registro de visita",
         "listVets": "Veterinários", "listPetTypes": "Tipos de animal", "createOwner": "Cadastro"}

# As figuras entram na monografia reduzidas a cerca de 12 cm; o corpo padrão do
# matplotlib ficaria ilegível na impressão.
plt.rcParams.update({"font.size": 12, "axes.titlesize": 12, "axes.labelsize": 12,
                     "legend.fontsize": 10, "xtick.labelsize": 11, "ytick.labelsize": 11})

# Descarte de aquecimento (§3.7): só no cenário constante e só em mono/micro, para
# excluir JIT e cache. No serverless o cold start é a medição de interesse, e em
# rampa/pico os transitórios são o objeto de estudo. Use 0 em runs -Quick.
WARMUP_SEC = int(os.environ.get("WARMUP_SEC", "60"))
WARMUP_TARGETS = ("mono", "micro")

# Alocação por componente (Quadro 2 / infra/terraform/microservices.tf).
ALLOC_VCPU_GB = {
    ("Monolito", "ec2"): (2.0, 4.0),
    ("MySQL", "ec2"): (2.0, 8.0),
    ("Microsserviços", "config-server"): (0.25, 0.5),
    ("Microsserviços", "discovery-server"): (0.25, 0.5),
    ("Microsserviços", "customers-service"): (0.5, 1.0),
    ("Microsserviços", "vets-service"): (0.25, 0.5),
    ("Microsserviços", "visits-service"): (0.25, 0.5),
    ("Microsserviços", "api-gateway"): (0.5, 1.0),
}
MICRO_CPU_UNITS = 2048           # soma das 6 tarefas (2 vCPU)
LAMBDA_MEM_MB = 1769             # ≈ 1 vCPU por invocação
PLATFORM_SERVICES = {"config-server", "discovery-server", "api-gateway"}


def parse_raw(path):
    """Extrai os Points de http_req_duration (1 por requisição) e os de
    agg_visits_present (1 por ficha agregada; valor 1 quando a ficha veio com visitas).

    Os dois vêm da mesma passada porque o bruto de uma repetição chega a 130 MB e
    reler o arquivo por métrica dobraria o tempo de análise da campanha."""
    t, dur, st, op = [], [], [], []
    at, av = [], []
    with open(path, encoding="utf-8") as f:
        for line in f:
            is_http = '"http_req_duration"' in line
            if not is_http and '"agg_visits_present"' not in line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if o.get("type") != "Point":
                continue
            d = o["data"]
            if o.get("metric") == "agg_visits_present":
                at.append(d["time"]); av.append(d["value"])
                continue
            if o.get("metric") != "http_req_duration":
                continue
            tags = d.get("tags", {})
            t.append(d["time"]); dur.append(d["value"])
            st.append(tags.get("status", "")); op.append(tags.get("op", ""))
    df = pd.DataFrame({"time": t, "duration_ms": dur, "status": st, "op": op})
    if not df.empty:
        df["time"] = pd.to_datetime(df["time"], format="ISO8601", utc=True)
    agg = pd.DataFrame({"time": at, "present": av})
    if not agg.empty:
        agg["time"] = pd.to_datetime(agg["time"], format="ISO8601", utc=True)
    return df, agg


def load_all():
    frames, aframes = [], []
    pattern = os.path.join(RESULTS, "*", "*", "*-raw.json")
    for raw in glob.glob(pattern):
        fname = os.path.basename(raw)
        m = re.match(r"(constant|ramp|spike)(?:-rep(\d+))?-raw\.json$", fname)
        if not m:
            continue
        run = os.path.basename(os.path.dirname(raw))
        target = os.path.basename(os.path.dirname(os.path.dirname(raw)))
        scenario, rep = m.group(1), int(m.group(2) or 1)
        df, agg = parse_raw(raw)
        if df.empty:
            continue
        df["target"], df["run"], df["scenario"], df["rep"] = target, run, scenario, rep
        frames.append(df)
        if not agg.empty:
            agg["target"], agg["run"], agg["scenario"], agg["rep"] = target, run, scenario, rep
            aframes.append(agg)
    if not frames:
        sys.exit(f"Nenhum *-raw.json encontrado em {RESULTS}/<alvo>/<ts>/")
    alldf = pd.concat(frames, ignore_index=True)
    for t, n in alldf.groupby("target")["run"].nunique().items():
        if n > 1:
            print(f"[aviso] '{t}' tem {n} execuções em {RESULTS}/ — cada (execução, repetição) "
                  f"conta como uma repetição distinta.", file=sys.stderr)
    alldf["failed"] = ~alldf["status"].astype(str).str.match(r"[23]..").fillna(False)
    aggdf = (pd.concat(aframes, ignore_index=True) if aframes
             else pd.DataFrame(columns=["time", "present", "target", "run", "scenario", "rep"]))
    return alldf, aggdf


def order_targets(ts):
    return [t for t in TARGET_ORDER if t in set(ts)]


def per_rep_metrics(alldf, warmup_targets=WARMUP_TARGETS):
    rows = []
    # 'run' entra na chave: repetições homônimas de execuções distintas não podem
    # ser fundidas — o intervalo entre elas destruiria o throughput.
    for (t, s, run, rep), g in alldf.groupby(["target", "scenario", "run", "rep"]):
        if s == "constant" and WARMUP_SEC > 0 and t in warmup_targets:
            cut = g["time"].min() + pd.Timedelta(seconds=WARMUP_SEC)
            g = g[g["time"] >= cut]
            if g.empty:
                continue
        dur = g["duration_ms"].to_numpy()
        span = (g["time"].max() - g["time"].min()).total_seconds()
        rows.append({
            "target": t, "scenario": s, "run": run, "rep": rep, "n": len(g),
            "throughput_rps": len(g) / span if span > 0 else np.nan,
            "error_rate_pct": 100 * g["failed"].mean(),
            "mean_ms": dur.mean(), "median_ms": float(np.median(dur)),
            "p95_ms": float(np.percentile(dur, 95)),
            "p99_ms": float(np.percentile(dur, 99)),
        })
    return pd.DataFrame(rows)


def warmup_sensitivity(alldf):
    """Aplica ao serverless o mesmo descarte de aquecimento das contínuas, separando a
    penalidade de inicialização da penalidade de regime (§3.7)."""
    srv = [t for t in alldf.target.unique() if str(t).startswith("serverless")]
    if not srv or WARMUP_SEC <= 0:
        return None
    keys = ["target", "scenario", "run", "rep"]
    m = per_rep_metrics(alldf, WARMUP_TARGETS).merge(
        per_rep_metrics(alldf, tuple(WARMUP_TARGETS) + tuple(srv)),
        on=keys, suffixes=("_sem", "_com"))
    m = m[m.target.isin(srv) & (m.scenario == "constant")]
    if m.empty:
        return None
    out = m.groupby(["target"]).agg(
        mediana_sem_descarte=("median_ms_sem", "mean"),
        mediana_com_descarte=("median_ms_com", "mean"),
        p95_sem_descarte=("p95_ms_sem", "mean"),
        p95_com_descarte=("p95_ms_com", "mean"),
    ).reset_index()
    out.to_csv(os.path.join(TAB, "warmup_sensitivity.csv"), index=False)
    return out


def ci95(x):
    x = pd.Series(x).dropna().to_numpy()
    if len(x) < 2:
        return 0.0
    return float(stats.t.ppf(0.975, len(x) - 1) * x.std(ddof=1) / np.sqrt(len(x)))


def summarize(per_rep):
    rows = []
    for (t, s), g in per_rep.groupby(["target", "scenario"]):
        row = {"target": t, "scenario": s, "reps": len(g)}
        for m in METRICS:
            row[f"{m}_mean"] = g[m].mean()
            row[f"{m}_ci"] = ci95(g[m])
        rows.append(row)
    return pd.DataFrame(rows)


def grouped_bar(summary, metric, ylabel, title, fname):
    piv = summary.pivot(index="scenario", columns="target", values=f"{metric}_mean").reindex(SCN)
    cis = summary.pivot(index="scenario", columns="target", values=f"{metric}_ci").reindex(SCN)
    targets = order_targets(piv.columns)
    if not targets:
        return
    piv, cis = piv[targets], cis[targets]
    x = np.arange(len(SCN)); w = 0.8 / len(targets)
    fig, ax = plt.subplots(figsize=(8, 5))
    for i, t in enumerate(targets):
        ax.bar(x + i * w, piv[t], w, yerr=cis[t].fillna(0), capsize=4,
               label=LABEL.get(t, t), color=COLOR.get(t))
    ax.set_xticks(x + w * (len(targets) - 1) / 2)
    ax.set_xticklabels([SCNLAB[s] for s in SCN])
    ax.set_ylabel(ylabel); ax.set_title(title)
    ax.legend(title="Arquitetura"); ax.grid(axis="y", alpha=0.3)
    fig.tight_layout(); fig.savefig(os.path.join(FIG, fname), dpi=150); plt.close(fig)


def boxplots(alldf):
    for s in SCN:
        sub = alldf[alldf.scenario == s]
        targets = order_targets(sub.target.unique())
        if not targets:
            continue
        data = [sub[sub.target == t]["duration_ms"].to_numpy() for t in targets]
        fig, ax = plt.subplots(figsize=(7, 5))
        ax.boxplot(data, tick_labels=[LABEL[t] for t in targets], showfliers=False)
        ax.set_ylabel("Tempo de resposta (ms)")
        ax.set_title(f"Distribuição do tempo de resposta — {SCNLAB[s]}")
        ax.grid(axis="y", alpha=0.3)
        fig.tight_layout(); fig.savefig(os.path.join(FIG, f"box_{s}.png"), dpi=150); plt.close(fig)


def ecdf(alldf):
    for s in SCN:
        sub = alldf[alldf.scenario == s]
        targets = order_targets(sub.target.unique())
        if not targets:
            continue
        fig, ax = plt.subplots(figsize=(7, 5))
        for t in targets:
            d = np.sort(sub[sub.target == t]["duration_ms"].to_numpy())
            y = np.arange(1, len(d) + 1) / len(d)
            ax.plot(d, y, label=LABEL[t], color=COLOR.get(t))
        ax.set_xlabel("Tempo de resposta (ms)"); ax.set_ylabel("Proporção acumulada")
        ax.set_title(f"ECDF do tempo de resposta — {SCNLAB[s]}")
        ax.legend(title="Arquitetura"); ax.grid(alpha=0.3)
        fig.tight_layout(); fig.savefig(os.path.join(FIG, f"ecdf_{s}.png"), dpi=150); plt.close(fig)


def timeseries(alldf):
    """p95 por segundo ao longo do tempo — revela degradação (rampa) e saturação (pico)."""
    for s in ["ramp", "spike"]:
        sub = alldf[alldf.scenario == s]
        targets = order_targets(sub.target.unique())
        if not targets:
            continue
        fig, ax = plt.subplots(figsize=(9, 5))
        for t in targets:
            d = sub[sub.target == t].copy()
            d["sec"] = d.groupby(["run", "rep"])["time"].transform(lambda x: (x - x.min()).dt.total_seconds()).astype(int)
            g = d.groupby("sec")["duration_ms"].quantile(0.95)
            ax.plot(g.index, g.values, label=LABEL[t], linewidth=1.5, color=COLOR.get(t))
        ax.set_xlabel("Tempo do teste (s)"); ax.set_ylabel("p95 do tempo de resposta (ms)")
        ax.set_title(f"Evolução temporal do p95 — {SCNLAB[s]}")
        ax.legend(title="Arquitetura"); ax.grid(alpha=0.3)
        fig.tight_layout(); fig.savefig(os.path.join(FIG, f"timeseries_{s}.png"), dpi=150); plt.close(fig)


def cliffs_delta(a, b):
    """Tamanho de efeito não paramétrico: proporção de pares em que a>b menos a
    proporção em que a<b. Com n=10 e diferenças grandes o p-valor satura, e só o
    delta informa a magnitude."""
    a, b = np.asarray(a), np.asarray(b)
    if not len(a) or not len(b):
        return np.nan
    gt = sum(int((x > b).sum()) for x in a)
    lt = sum(int((x < b).sum()) for x in a)
    return (gt - lt) / (len(a) * len(b))


def delta_label(d):
    # limiares usuais de Romano et al. para interpretação do delta
    ad = abs(d)
    return ("desprezível" if ad < 0.147 else "pequeno" if ad < 0.33
            else "médio" if ad < 0.474 else "grande")


def compare_groups(per_rep, metric, title, lines):
    """Shapiro-Wilk por grupo, Kruskal-Wallis global e Mann-Whitney par a par com
    Bonferroni e Cliff's delta. Unidade amostral: a repetição (§3.7)."""
    lines.append(f"=== {title} — {metric} ===")
    for s in SCN:
        sub = per_rep[per_rep.scenario == s]
        targets = order_targets(sub.target.unique())
        if len(targets) < 2:
            continue
        groups = [sub[sub.target == t][metric].dropna().to_numpy() for t in targets]
        lines.append(f"[{SCNLAB[s]}]")
        lines.append("  Normalidade (Shapiro-Wilk):")
        for t, x in zip(targets, groups):
            if len(x) >= 3:
                W, pw = stats.shapiro(x)
                lines.append(f"    {LABEL[t]} (n={len(x)}): W={W:.3f}, p={pw:.2e} "
                             f"({'normal' if pw >= 0.05 else 'não-normal'} a 5%)")
            else:
                lines.append(f"    {LABEL[t]} (n={len(x)}): amostra insuficiente para Shapiro-Wilk")
        H, p = stats.kruskal(*groups)
        lines.append(f"  Kruskal-Wallis: H={H:.2f}, p={p:.2e} "
                     f"({'diferença significativa' if p < 0.05 else 'sem diferença'})")
        pairs = [(i, j) for i in range(len(targets)) for j in range(i + 1, len(targets))]
        nb = max(len(pairs), 1)
        for i, j in pairs:
            U, pu = stats.mannwhitneyu(groups[i], groups[j], alternative="two-sided")
            med_i, med_j = np.median(groups[i]), np.median(groups[j])
            d = cliffs_delta(groups[i], groups[j])
            ratio = med_i / med_j if med_j else np.nan
            lines.append(f"    {LABEL[targets[i]]} vs {LABEL[targets[j]]}: "
                         f"p={min(pu*nb,1):.2e} (Bonferroni) | delta={d:+.2f} ({delta_label(d)}) | "
                         f"medianas {med_i:.1f} vs {med_j:.1f} ms (razão {ratio:.2f}x)")
        lines.append("")


def stat_tests(per_rep, owner_detail=None):
    lines = ["Comparação entre arquiteturas — unidade amostral: a repetição (§3.7).",
             "Normalidade: Shapiro-Wilk por grupo | Comparação: Kruskal-Wallis + Mann-Whitney",
             "com correção de Bonferroni | Magnitude: Cliff's delta e razão de medianas\n"]
    for m in ("median_ms", "p95_ms"):
        compare_groups(per_rep, m, "TODAS as requisições", lines)
    if owner_detail is not None and not owner_detail.empty:
        for m in ("median_ms", "p95_ms"):
            compare_groups(owner_detail, m, "OPERAÇÃO DISCRIMINANTE (ficha agregada)", lines)
    txt = "\n".join(lines)
    with open(os.path.join(TAB, "stats_tests.txt"), "w", encoding="utf-8") as f:
        f.write(txt)
    return txt


def owner_detail_comparison(alldf):
    """Compara SÓ a operação discriminante (ficha agregada owner+pets+visits).
    É onde o monolito (em processo) difere dos microsserviços (entre serviços)."""
    sub = alldf[alldf["op"] == "ownerDetail"]
    if sub.empty:
        return None, None
    rows = []
    for (t, s, run, rep), g in sub.groupby(["target", "scenario", "run", "rep"]):
        d = g["duration_ms"].to_numpy()
        rows.append({"target": t, "scenario": s, "run": run, "rep": rep,
                     "median_ms": float(np.median(d)), "p95_ms": float(np.percentile(d, 95))})
    pr = pd.DataFrame(rows)
    pr.to_csv(os.path.join(TAB, "owner_detail_per_rep.csv"), index=False)

    sm = []
    for (t, s), g in pr.groupby(["target", "scenario"]):
        sm.append({"target": t, "scenario": s,
                   "median_ms": g["median_ms"].mean(),
                   "p95_ms_mean": g["p95_ms"].mean(), "p95_ms_ci": ci95(g["p95_ms"])})
    sm = pd.DataFrame(sm)

    piv = sm.pivot(index="scenario", columns="target", values="p95_ms_mean").reindex(SCN)
    cis = sm.pivot(index="scenario", columns="target", values="p95_ms_ci").reindex(SCN)
    targets = order_targets(piv.columns)
    if targets:
        x = np.arange(len(SCN)); w = 0.8 / len(targets)
        fig, ax = plt.subplots(figsize=(8, 5))
        for i, t in enumerate(targets):
            ax.bar(x + i * w, piv[t], w, yerr=cis[t].fillna(0), capsize=4,
                   label=LABEL.get(t, t), color=COLOR.get(t))
        ax.set_xticks(x + w * (len(targets) - 1) / 2)
        ax.set_xticklabels([SCNLAB[s] for s in SCN])
        ax.set_ylabel("p95 (ms)")
        ax.set_title("Ficha do owner (AGREGAÇÃO owner+pets+visits) — p95 por arquitetura\n"
                     "(resolução em processo × distribuída entre serviços/funções)")
        ax.legend(title="Arquitetura"); ax.grid(axis="y", alpha=0.3)
        fig.tight_layout(); fig.savefig(os.path.join(FIG, "bar_owner_detail_p95.png"), dpi=150); plt.close(fig)
    return pr, sm


def by_operation(alldf, scenario="constant"):
    """p95 por operação e arquitetura: mostra ONDE nasce a diferença, e não apenas
    que ela existe. A ficha agregada aparece ao lado das operações simples do mesmo
    teste, o que dá a razão entre elas."""
    sub = alldf[(alldf.scenario == scenario) & (alldf["op"].astype(str) != "")]
    if sub.empty:
        return None
    rows = []
    for (t, op, run, rep), g in sub.groupby(["target", "op", "run", "rep"]):
        d = g["duration_ms"].to_numpy()
        rows.append({"target": t, "op": op, "run": run, "rep": rep,
                     "median_ms": float(np.median(d)), "p95_ms": float(np.percentile(d, 95))})
    sm = pd.DataFrame(rows).groupby(["target", "op"]).agg(
        median_mean=("median_ms", "mean"), p95_mean=("p95_ms", "mean"), p95_ci=("p95_ms", ci95),
    ).reset_index()
    sm.to_csv(os.path.join(TAB, "by_operation.csv"), index=False)

    ops = [o for o in OPORDER if o in set(sm.op)]
    targets = order_targets(sm.target.unique())
    if not ops or not targets:
        return sm
    x = np.arange(len(ops)); w = 0.8 / len(targets)
    fig, ax = plt.subplots(figsize=(9, 5))
    for i, t in enumerate(targets):
        d = sm[sm.target == t].set_index("op").reindex(ops)
        ci = d["p95_ci"].fillna(0)
        # escala log: o erro inferior não pode cruzar o zero
        lo = np.minimum(ci, d["p95_mean"] * 0.99)
        ax.bar(x + i * w, d["p95_mean"], w, yerr=[lo, ci], capsize=3,
               label=LABEL.get(t, t), color=COLOR.get(t))
    ax.set_xticks(x + w * (len(targets) - 1) / 2)
    ax.set_xticklabels([OPLAB.get(o, o) for o in ops], rotation=20, ha="right")
    ax.set_yscale("log")  # as arquiteturas diferem em ordens de grandeza
    ax.set_ylabel("p95 (ms, escala log)")
    ax.set_title(f"Tempo de resposta por operação — {SCNLAB[scenario]}")
    ax.legend(title="Arquitetura"); ax.grid(axis="y", alpha=0.3)
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "bar_by_operation.png"), dpi=150); plt.close(fig)
    return sm


def _useful_per_sec(d, aggdf, target, scenario, thr, reps):
    """Série por segundo da vazão útil: a vazão total menos as fichas agregadas que
    voltaram vazias. Devolve None quando não há dado de agregação para o alvo."""
    if aggdf is None or aggdf.empty:
        return None
    a = aggdf[(aggdf.target == target) & (aggdf.scenario == scenario)]
    if a.empty:
        return None
    # O relógio da série é o da primeira requisição da repetição, não o da primeira
    # ficha: a ficha só ocorre depois da listagem, e origens distintas deslocariam
    # as duas séries entre si.
    t0 = d.groupby(["run", "rep"])["time"].min()
    a = a.join(t0.rename("t0"), on=["run", "rep"])
    a = a[a["t0"].notna()]
    if a.empty:
        return None
    a = a.assign(sec=((a["time"] - a["t0"]).dt.total_seconds()).astype(int))
    det = d[d.op == "ownerDetail"].groupby("sec").size().reindex(thr.index).fillna(0) / reps
    okagg = a.groupby("sec")["present"].sum().reindex(thr.index).fillna(0) / reps
    return (thr - det + okagg).clip(lower=0)


def useful_throughput(alldf, aggdf):
    """Vazão útil por repetição: desconta da vazão total as fichas que voltaram sem
    visitas. Sob estresse o disjuntor do gateway responde 200 com a lista de visitas
    vazia, e contar essas respostas como trabalho entregue creditaria à arquitetura
    uma capacidade que ela não sustentou. É o mesmo critério que a calibração já
    aplica às requisições com erro."""
    if aggdf is None or aggdf.empty:
        return None
    keys = ["target", "scenario", "run", "rep"]
    fichas = {k: v for k, v in aggdf.groupby(keys)}
    rows = []
    for (t, sc, run, rep), g in alldf.groupby(keys):
        a = fichas.get((t, sc, run, rep))
        if a is None:
            continue
        # Mesmo recorte de per_rep_metrics, para a vazão total desta tabela bater com
        # a de summary.csv. As fichas seguem o mesmo corte: aparar só as requisições
        # subtrairia fichas de um intervalo que já não está no numerador.
        if sc == "constant" and WARMUP_SEC > 0 and t in WARMUP_TARGETS:
            cut = g["time"].min() + pd.Timedelta(seconds=WARMUP_SEC)
            g, a = g[g["time"] >= cut], a[a["time"] >= cut]
            if g.empty:
                continue
        span = (g["time"].max() - g["time"].min()).total_seconds()
        if span <= 0:
            continue
        n_ok, n_det = a["present"].sum(), len(a)
        total = len(g)
        rows.append({"target": t, "scenario": sc, "run": run, "rep": rep,
                     "vazao_total_rps": total / span,
                     "vazao_util_rps": (total - n_det + n_ok) / span,
                     "fichas": n_det, "fichas_completas": n_ok,
                     "share_ficha": n_det / total if total else np.nan})
    if not rows:
        return None
    per = pd.DataFrame(rows)
    agg = per.groupby(["target", "scenario"]).agg(
        reps=("rep", "size"),
        vazao_total_rps=("vazao_total_rps", "mean"),
        vazao_util_rps=("vazao_util_rps", "mean"),
        share_ficha=("share_ficha", "mean"),
    ).reset_index()
    agg["fichas_completas_pct"] = 100 * (per.groupby(["target", "scenario"])["fichas_completas"].sum()
                                         / per.groupby(["target", "scenario"])["fichas"].sum()).values
    agg["perda_pct"] = 100 * (1 - agg["vazao_util_rps"] / agg["vazao_total_rps"])
    agg.to_csv(os.path.join(TAB, "useful_throughput.csv"), index=False)
    return agg


def scalability(alldf, aggdf=None):
    """Curva de escalabilidade (throughput sob carga crescente) para rampa e pico.
    O ponto de saturação sai APENAS do pico (§3.7): a rampa é de modelo fechado e o
    throughput ali é limitado pela carga ofertada, não pela capacidade. É o maior
    throughput sustentado por uma janela inteira com taxa de erro abaixo do limiar
    (env SAT_ERR_THRESHOLD, padrão 2%; SAT_WINDOW_SEC, padrão 10 s)."""
    thr_err = float(os.environ.get("SAT_ERR_THRESHOLD", "0.02"))
    win = int(os.environ.get("SAT_WINDOW_SEC", "10"))
    rows = []
    for s in ["ramp", "spike"]:
        sub = alldf[alldf.scenario == s]
        targets = order_targets(sub.target.unique())
        if not targets:
            continue
        fig, ax = plt.subplots(figsize=(9, 5))
        for t in targets:
            d = sub[sub.target == t].copy()
            reps = max(d.groupby(["run", "rep"]).ngroups, 1)
            d["sec"] = d.groupby(["run", "rep"])["time"].transform(lambda x: (x - x.min()).dt.total_seconds()).astype(int)
            g = d.groupby("sec")
            thr = g.size() / reps  # throughput médio por segundo (entre repetições)
            err = g["failed"].mean().reindex(thr.index).fillna(0)
            ax.plot(thr.index, thr.values, label=LABEL[t], linewidth=1.5, color=COLOR.get(t))
            if s != "spike":
                continue
            mp = max(win // 2, 1)
            thr_w = thr.rolling(win, center=True, min_periods=mp).median()
            err_w = err.rolling(win, center=True, min_periods=mp).max()
            ok = thr_w[err_w < thr_err]
            row = {
                "target": t, "scenario": s,
                "throughput_max_sustentavel_rps": round(float(ok.max()), 1) if len(ok) else float("nan"),
                "throughput_pico_rps": round(float(thr.max()), 1),
                "erro_max_pct": round(100 * float(err.max()), 2),
                "vazao_util_max_rps": float("nan"),
            }
            util = _useful_per_sec(d, aggdf, t, s, thr, reps)
            if util is not None:
                util_ok = util.rolling(win, center=True, min_periods=mp).median()[err_w < thr_err]
                if len(util_ok):
                    row["vazao_util_max_rps"] = round(float(util_ok.max()), 1)
            rows.append(row)
        ax.set_xlabel("Tempo do teste (s) — carga ofertada crescente")
        ax.set_ylabel("Throughput alcançado (req/s)")
        ax.set_title(f"Escalabilidade — throughput sob carga ({SCNLAB[s]})")
        ax.legend(title="Arquitetura")
        ax.grid(alpha=0.3)
        fig.tight_layout()
        fig.savefig(os.path.join(FIG, f"scalability_{s}.png"), dpi=150)
        plt.close(fig)
    sat = pd.DataFrame(rows)
    if not sat.empty:
        sat.to_csv(os.path.join(TAB, "saturation.csv"), index=False)
    return sat


def resource_usage():
    """Uso de recursos por arquitetura (verificação da equivalência — §3.4), lido de
    results/resources/usage*.csv (cloudwatch-capture.ps1).

    Converte a utilização percentual em vCPU e GB absolutos: a média de percentuais
    entre componentes de tamanhos diferentes não é comparável ao monolito, e é o
    valor absoluto que a equivalência declarada no Quadro 2 afirma."""
    paths = glob.glob(os.path.join(RESULTS, "resources", "usage*.csv"))
    if not paths:
        return None
    df = pd.concat([pd.read_csv(p) for p in paths], ignore_index=True)
    for c in ["cpu_avg_pct", "cpu_max_pct", "mem_avg_pct", "mem_max_pct"]:
        if c not in df.columns:
            df[c] = np.nan
    alloc = [ALLOC_VCPU_GB.get((a, c), (np.nan, np.nan))
             for a, c in zip(df["architecture"], df["component"])]
    df["vcpu_alloc"] = [a[0] for a in alloc]
    df["gb_alloc"] = [a[1] for a in alloc]
    for col, pct, base in [("vcpu_avg", "cpu_avg_pct", "vcpu_alloc"), ("vcpu_max", "cpu_max_pct", "vcpu_alloc"),
                           ("gb_avg", "mem_avg_pct", "gb_alloc"), ("gb_max", "mem_max_pct", "gb_alloc")]:
        df[col] = df[pct] / 100 * df[base]
    df.to_csv(os.path.join(TAB, "resource_usage_components.csv"), index=False)

    agg = df.groupby("architecture").agg(
        vcpu_alocada=("vcpu_alloc", "sum"), vcpu_media=("vcpu_avg", "sum"), vcpu_pico=("vcpu_max", "sum"),
        gb_alocada=("gb_alloc", "sum"), gb_media=("gb_avg", "sum"), gb_pico=("gb_max", "sum"),
    ).reset_index()
    # O serverless não tem capacidade contratada; da captura de cold start vem o pico
    # de memória por invocação, que é o único análogo disponível.
    srv = agg.architecture == "Serverless"
    agg.loc[srv, ["vcpu_alocada", "vcpu_media", "vcpu_pico", "gb_alocada", "gb_media", "gb_pico"]] = np.nan
    cs = os.path.join(TAB, "coldstart_summary.csv")
    if srv.any() and os.path.exists(cs):
        try:
            mb = pd.read_csv(cs)["mem_used_max_mb"].max()
            if pd.notna(mb):
                agg.loc[srv, "gb_pico"] = mb / 1024
        except (OSError, ValueError, KeyError):
            pass
    agg.to_csv(os.path.join(TAB, "resource_usage.csv"), index=False)

    sub = agg[agg.architecture.isin(["Monolito", "Microsserviços"])]
    if not sub.empty and sub["vcpu_media"].notna().any():
        x = np.arange(len(sub)); w = 0.38
        fig, ax = plt.subplots(figsize=(7, 5))
        ax.bar(x - w / 2, sub["vcpu_media"], w, label="vCPU média utilizada")
        ax.bar(x + w / 2, sub["gb_media"], w, label="GB médios utilizados")
        for i, (_, r) in enumerate(sub.iterrows()):
            ax.text(i, np.nanmax([r["vcpu_media"], r["gb_media"]]),
                    f"alocado: {r['vcpu_alocada']:.1f} vCPU / {r['gb_alocada']:.1f} GB",
                    ha="center", va="bottom", fontsize=8)
        ax.set_xticks(x); ax.set_xticklabels(sub["architecture"])
        ax.set_ylabel("Uso absoluto (vCPU e GB)")
        ax.set_title("Uso de recursos por arquitetura (verificação da equivalência)")
        ax.legend(); ax.grid(axis="y", alpha=0.3)
        fig.tight_layout(); fig.savefig(os.path.join(FIG, "resource_usage.png"), dpi=150); plt.close(fig)
    return agg


def platform_overhead():
    """Divide o consumo das tarefas entre lógica de negócio, plataforma e proxy do
    Service Connect (containers-micro.csv). O proxy divide o orçamento da tarefa com a
    aplicação: sem separá-lo, o custo da malha de comunicação entra no número da
    aplicação e a equivalência do Quadro 2 fica sobrestimada."""
    path = os.path.join(RESULTS, "resources", "containers-micro.csv")
    if not os.path.exists(path):
        return None
    try:
        df = pd.read_csv(path)
    except (OSError, ValueError):
        return None
    if "ContainerName" not in df.columns:
        return None

    def role(n):
        n = str(n)
        if "service-connect" in n or "envoy" in n.lower():
            return "proxy (Service Connect)"
        return "plataforma" if n in PLATFORM_SERVICES else "lógica de negócio"

    df["papel"] = df["ContainerName"].map(role)
    for c in ("cpu_units_avg", "cpu_units_max", "mem_mb_avg", "mem_mb_max"):
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")
    agg = df.groupby("papel").agg(
        cpu_units_med=("cpu_units_avg", "sum"), cpu_units_pico=("cpu_units_max", "sum"),
        mem_mb_med=("mem_mb_avg", "sum"), mem_mb_pico=("mem_mb_max", "sum"),
    ).reset_index()
    tot = agg["cpu_units_med"].sum()
    agg["pct_do_consumo"] = 100 * agg["cpu_units_med"] / tot if tot else np.nan
    agg["pct_do_orcamento"] = 100 * agg["cpu_units_med"] / MICRO_CPU_UNITS
    agg.to_csv(os.path.join(TAB, "platform_overhead.csv"), index=False)
    return agg


LAMBDA_FN_OP = {"getAllOwners": "listOwners", "getOwnerById": "ownerDetail",
                "listVets": "listVets", "listPetTypes": "listPetTypes",
                "createOwner": "createOwner", "createVisit": "createVisit"}


def lambda_consumption():
    """Consumo faturado do Lambda por função (results/resources/lambda-invocacoes-por-funcao.csv).

    O vCPU-segundo do serverless é a duração faturada vezes a fração de vCPU que a
    memória contratada representa. Diferente das outras arquiteturas, a duração
    faturada inclui a espera por E/S, então o número mede o que a AWS cobra, não a
    CPU efetivamente ocupada."""
    path = os.path.join(RESULTS, "resources", "lambda-invocacoes-por-funcao.csv")
    df = _read_csv(path)
    if df is None or "duracao_soma_ms" not in df.columns:
        return None
    df = df.copy()
    df["subcenario"] = np.where(df["funcao"].str.contains("-snap-"), "SnapStart", "Sem otimização")
    df["operacao"] = df["funcao"].str.rsplit("-", n=1).str[-1].map(LAMBDA_FN_OP)
    df["vcpu_s"] = df["duracao_soma_ms"] / 1000.0 * (df["memoria_mb"] / LAMBDA_MEM_MB)
    df["req_por_vcpu_s"] = df["invocacoes"] / df["vcpu_s"]
    out = df[["subcenario", "operacao", "funcao", "invocacoes", "duracao_media_ms",
              "vcpu_s", "req_por_vcpu_s"]].sort_values(["subcenario", "operacao"])
    out.to_csv(os.path.join(TAB, "lambda_consumption.csv"), index=False)
    return out


def normalized_efficiency(alldf, res):
    """Requisicoes atendidas por vCPU-segundo consumida (§3.4). E o denominador comum
    entre capacidade contratada e capacidade elastica: no serverless nao ha capacidade
    total, mas ha consumo faturado.

    As quatro linhas usam a janela da campanha inteira, e nao a de um cenario, porque
    a captura do CloudWatch cobre o braco de ponta a ponta e o consumo nao e separavel
    por cenario depois do fato. As janelas dos quatro bracos tem a mesma duracao e
    menos de 2% de tempo ocioso, entao a base e comparavel.

    Ressalva que o numero carrega: nas arquiteturas continuas o vCPU vem da CPU
    ocupada, enquanto no serverless vem da duracao faturada, que corre tambem
    enquanto a funcao espera o banco. Sao a mesma unidade de cobranca, nao a mesma
    medida de trabalho."""
    rows = []
    span = alldf.groupby("target")["time"].agg(lambda x: (x.max() - x.min()).total_seconds())
    reqs = alldf.groupby("target").size()
    if res is not None:
        for arch, tgt in (("Monolito", "mono"), ("Microsserviços", "micro")):
            r = res[res.architecture == arch]
            if r.empty or tgt not in span.index or not span[tgt]:
                continue
            vcpu = float(r["vcpu_media"].iloc[0])
            if not vcpu or np.isnan(vcpu):
                continue
            thr = reqs[tgt] / span[tgt]
            rows.append({"arquitetura": arch, "requisicoes": int(reqs[tgt]),
                         "janela_s": round(float(span[tgt]), 1),
                         "throughput_rps": round(thr, 1), "vcpu_media": round(vcpu, 3),
                         "req_por_vcpu_s": round(thr / vcpu, 1)})
    lam = lambda_consumption()
    if lam is not None:
        for sub, g in lam.groupby("subcenario", sort=False):
            tgt = "serverless-snap" if "snap" in sub.lower() else "serverless-cold"
            if tgt not in span.index or not span[tgt]:
                continue
            vcpu_s, inv = g["vcpu_s"].sum(), g["invocacoes"].sum()
            rows.append({"arquitetura": f"Serverless ({sub})", "requisicoes": int(inv),
                         "janela_s": round(float(span[tgt]), 1),
                         "throughput_rps": round(inv / span[tgt], 1),
                         "vcpu_media": round(vcpu_s / span[tgt], 3),
                         "req_por_vcpu_s": round(inv / vcpu_s, 1)})
    if not rows:
        return None
    eff = pd.DataFrame(rows)
    eff.to_csv(os.path.join(TAB, "normalized_efficiency.csv"), index=False)
    return eff


def _read_csv(path):
    if not os.path.exists(path):
        return None
    try:
        return pd.read_csv(path)
    except (OSError, ValueError):
        return None


def run_conditions():
    """Condições de execução por repetição (§4.1): iterações descartadas, VUs usados,
    deriva de payload, RTT de base e CPU do gerador. Sustenta a afirmação da §3.4 de
    que o cliente não se tornou o fator limitante."""
    rows = []
    for rundir in glob.glob(os.path.join(RESULTS, "*", "*")):
        if not os.path.isdir(rundir):
            continue
        target = os.path.basename(os.path.dirname(rundir))
        rtt = _read_csv(os.path.join(rundir, "baseline-latency.csv"))
        cpu = _read_csv(os.path.join(rundir, "client-cpu.csv"))
        for summ in glob.glob(os.path.join(rundir, "*-summary.json")):
            m = re.match(r"(constant|ramp|spike)-rep(\d+)-summary\.json$", os.path.basename(summ))
            if not m:
                continue
            scenario, rep = m.group(1), int(m.group(2))
            try:
                with open(summ, encoding="utf-8") as f:
                    mt = json.load(f).get("metrics", {})
            except (OSError, ValueError):
                continue
            reqs = mt.get("http_reqs", {}).get("count", 0)
            row = {
                "target": target, "scenario": scenario,
                "run": os.path.basename(rundir), "rep": rep,
                "iterations": mt.get("iterations", {}).get("count", 0),
                "http_reqs": reqs,
                # o k6 só emite a métrica quando houve descarte
                "dropped_iterations": mt.get("dropped_iterations", {}).get("count", 0),
                "vus_max": mt.get("vus_max", {}).get("max", np.nan),
                "kb_per_req": (mt.get("data_received", {}).get("count", 0) / reqs / 1024) if reqs else np.nan,
                # queda desta taxa sob carga = circuit breaker do gateway abrindo e
                # devolvendo visitas vazias, ou seja, agregação que não agregou
                "agg_visits_present": mt.get("agg_visits_present", {}).get("value", np.nan),
                # quantas visitas a ficha trouxe: se um braço agrega menos que outro,
                # a operação discriminante não é a mesma nos dois
                "agg_visit_count_med": mt.get("agg_visit_count", {}).get("med", np.nan),
                # corpo médio das respostas; o detalhamento por operação fica no bruto
                "resp_bytes_avg": mt.get("op_response_bytes", {}).get("avg", np.nan),
                "rtt_min_ms": np.nan, "client_cpu_avg_pct": np.nan, "client_cpu_max_pct": np.nan,
            }
            if rtt is not None and {"scenario", "rep"} <= set(rtt.columns):
                r = rtt[(rtt.scenario == scenario) & (rtt.rep == rep)]["min_rtt_ms"].dropna()
                if len(r):
                    row["rtt_min_ms"] = float(r.iloc[0])
            if cpu is not None and {"scenario", "rep"} <= set(cpu.columns):
                c = cpu[(cpu.scenario == scenario) & (cpu.rep == rep)]["cpu_pct"].dropna()
                if len(c):
                    row["client_cpu_avg_pct"] = float(c.mean())
                    row["client_cpu_max_pct"] = float(c.max())
            rows.append(row)
    if not rows:
        return None
    cond = pd.DataFrame(rows).sort_values(["target", "scenario", "run", "rep"])
    cond.to_csv(os.path.join(TAB, "run_conditions.csv"), index=False)

    agg = cond.groupby(["target", "scenario"]).agg(
        reps=("rep", "size"),
        iter_descartadas=("dropped_iterations", "sum"),
        vus_max=("vus_max", "max"),
        kb_por_req=("kb_per_req", "mean"),
        rtt_min_ms=("rtt_min_ms", "median"),
        cpu_cliente_med=("client_cpu_avg_pct", "mean"),
        cpu_cliente_max=("client_cpu_max_pct", "max"),
        agg_com_visitas=("agg_visits_present", "mean"),
    ).reset_index()
    agg.to_csv(os.path.join(TAB, "run_conditions_summary.csv"), index=False)
    return agg


def first_rep_sensitivity(per_rep):
    """Compara as metricas com e sem a primeira repeticao de cada celula.

    A primeira repeticao apos o provisionamento paga JIT, cache e pool de conexoes
    frios, e no serverless paga tambem os ambientes de execucao ainda nao criados.
    A tabela existe como verificacao de robustez: o resultado principal usa as dez
    repeticoes, e descartar a primeira depois de ver os dados seria escolher o
    recorte pelo efeito que ele produz."""
    rows = []
    for (t, sc), g in per_rep.groupby(["target", "scenario"]):
        g = g.sort_values("rep")
        sem = g[g.rep > g.rep.min()]
        if len(sem) < 2:
            continue
        row = {"target": t, "scenario": sc, "reps": len(g)}
        for m in ("throughput_rps", "p95_ms"):
            a, b = g[m].to_numpy(dtype=float), sem[m].to_numpy(dtype=float)
            row[f"{m}_com_rep1"] = a.mean()
            row[f"{m}_sem_rep1"] = b.mean()
            row[f"{m}_delta_pct"] = 100 * (b.mean() - a.mean()) / a.mean() if a.mean() else np.nan
            row[f"{m}_cv_com_pct"] = 100 * a.std(ddof=1) / a.mean() if a.mean() else np.nan
            row[f"{m}_cv_sem_pct"] = 100 * b.std(ddof=1) / b.mean() if b.mean() else np.nan
        rows.append(row)
    if not rows:
        return None
    frs = pd.DataFrame(rows)
    frs.to_csv(os.path.join(TAB, "first_rep_sensitivity.csv"), index=False)
    return frs


def main():
    alldf, aggdf = load_all()
    per_rep = per_rep_metrics(alldf)
    summary = summarize(per_rep)

    per_rep.to_csv(os.path.join(TAB, "per_rep.csv"), index=False)
    summary.to_csv(os.path.join(TAB, "summary.csv"), index=False)

    # Throughput e taxa de erro ficam em tabela (summary.csv): em modelo fechado o
    # throughput é função da latência, e o erro é ~0 fora do pico.
    grouped_bar(summary, "p95_ms", "p95 (ms)", "Tempo de resposta (p95) por arquitetura", "bar_p95.png")
    grouped_bar(summary, "p99_ms", "p99 (ms)", "Tempo de resposta (p99) por arquitetura", "bar_p99.png")
    boxplots(alldf); ecdf(alldf); timeseries(alldf)
    byop = by_operation(alldf)
    sat = scalability(alldf, aggdf)
    res = resource_usage()
    od_per_rep, od = owner_detail_comparison(alldf)
    tests = stat_tests(per_rep, od_per_rep)
    warm = warmup_sensitivity(alldf)
    over = platform_overhead()
    neff = normalized_efficiency(alldf, res)
    util = useful_throughput(alldf, aggdf)
    frs = first_rep_sensitivity(per_rep)

    cond = run_conditions()

    pd.set_option("display.width", 160, "display.max_columns", 30)
    if cond is not None:
        print("\n=== Condições de execução (§4.1) ===")
        print(cond.round(2).to_string(index=False))
    show = summary[["target", "scenario", "reps", "throughput_rps_mean",
                    "error_rate_pct_mean", "p95_ms_mean", "p99_ms_mean"]].round(2)
    print("\n=== Resumo por arquitetura × cenário (TODAS as requisições) ===")
    print(show.to_string(index=False))
    if od is not None:
        print("\n=== Operação DISCRIMINANTE: ficha agregada (ownerDetail) ===")
        print(od.round(2).to_string(index=False))
    if byop is not None:
        print("\n=== Tempo de resposta por operação (cenário constante) ===")
        print(byop.round(2).to_string(index=False))
    if not sat.empty:
        print("\n=== Escalabilidade: ponto de saturação (throughput sustentável, erro<2%) ===")
        print(sat.to_string(index=False))
    if res is not None:
        print("\n=== Uso de recursos por arquitetura (vCPU e GB absolutos) ===")
        print(res.round(2).to_string(index=False))
    if warm is not None:
        print("\n=== Sensibilidade ao descarte de aquecimento (serverless, constante) ===")
        print(warm.round(1).to_string(index=False))
    if over is not None:
        print("\n=== Orçamento das tarefas: negócio × plataforma × proxy ===")
        print(over.round(1).to_string(index=False))
    if neff is not None:
        print("\n=== Eficiência normalizada (req por vCPU-segundo consumida) ===")
        print(neff.round(2).to_string(index=False))
    if util is not None:
        print("\n=== Vazão útil (descontadas as fichas que voltaram vazias) ===")
        print(util.round(2).to_string(index=False))
    if frs is not None:
        print("\n=== Robustez: efeito da primeira repetição ===")
        print(frs.round(2).to_string(index=False))
    print("\n=== Testes estatísticos ===\n" + tests)
    print(f"Figuras em {FIG}/ | Tabelas em {TAB}/")


if __name__ == "__main__":
    main()
