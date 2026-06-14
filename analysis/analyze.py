"""
Análise dos resultados de carga (k6) para o TCC.

Lê os arquivos results/<alvo>/<timestamp>/<cenario>[-repNN]-raw.json, monta uma
tabela por requisição e produz:
  - tables/per_rep.csv ......... métricas por repetição (base do tratamento estatístico)
  - tables/summary.csv ......... média ± IC95% por (arquitetura, cenário)
  - tables/stats_tests.txt ..... Shapiro-Wilk + Kruskal-Wallis + Mann-Whitney (unidade: repetição)
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

# Descarte de aquecimento (seção 3.6): no cenário de carga CONSTANTE, ignora os
# primeiros WARMUP_SEC segundos para medir o regime estável, livre de efeitos
# transitórios (JIT da JVM, preenchimento de cache). Em rampa/pico NÃO se descarta
# (os transitórios são o objeto de estudo). Defina via env WARMUP_SEC.
WARMUP_SEC = int(os.environ.get("WARMUP_SEC", "0"))


def parse_raw(path):
    """Extrai os Points de http_req_duration (1 por requisição)."""
    t, dur, st, op = [], [], [], []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if '"http_req_duration"' not in line:
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            if o.get("type") != "Point" or o.get("metric") != "http_req_duration":
                continue
            d = o["data"]
            tags = d.get("tags", {})
            t.append(d["time"]); dur.append(d["value"])
            st.append(tags.get("status", "")); op.append(tags.get("op", ""))
    df = pd.DataFrame({"time": t, "duration_ms": dur, "status": st, "op": op})
    if not df.empty:
        df["time"] = pd.to_datetime(df["time"], format="ISO8601", utc=True)
    return df


def load_all():
    frames = []
    pattern = os.path.join(RESULTS, "*", "*", "*-raw.json")
    for raw in glob.glob(pattern):
        fname = os.path.basename(raw)
        m = re.match(r"(constant|ramp|spike)(?:-rep(\d+))?-raw\.json$", fname)
        if not m:
            continue
        target = os.path.basename(os.path.dirname(os.path.dirname(raw)))
        scenario, rep = m.group(1), int(m.group(2) or 1)
        df = parse_raw(raw)
        if df.empty:
            continue
        df["target"], df["scenario"], df["rep"] = target, scenario, rep
        frames.append(df)
    if not frames:
        sys.exit(f"Nenhum *-raw.json encontrado em {RESULTS}/<alvo>/<ts>/")
    alldf = pd.concat(frames, ignore_index=True)
    alldf["failed"] = ~alldf["status"].astype(str).str.match(r"[23]..").fillna(False)
    return alldf


def order_targets(ts):
    return [t for t in TARGET_ORDER if t in set(ts)]


def per_rep_metrics(alldf):
    rows = []
    for (t, s, rep), g in alldf.groupby(["target", "scenario", "rep"]):
        if s == "constant" and WARMUP_SEC > 0:
            cut = g["time"].min() + pd.Timedelta(seconds=WARMUP_SEC)
            g = g[g["time"] >= cut]
            if g.empty:
                continue
        dur = g["duration_ms"].to_numpy()
        span = (g["time"].max() - g["time"].min()).total_seconds()
        rows.append({
            "target": t, "scenario": s, "rep": rep, "n": len(g),
            "throughput_rps": len(g) / span if span > 0 else np.nan,
            "error_rate_pct": 100 * g["failed"].mean(),
            "mean_ms": dur.mean(), "median_ms": float(np.median(dur)),
            "p95_ms": float(np.percentile(dur, 95)),
            "p99_ms": float(np.percentile(dur, 99)),
        })
    return pd.DataFrame(rows)


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
        ax.bar(x + i * w, piv[t], w, yerr=cis[t].fillna(0), capsize=4, label=LABEL.get(t, t))
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
            ax.plot(d, y, label=LABEL[t])
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
            d["sec"] = d.groupby("rep")["time"].transform(lambda x: (x - x.min()).dt.total_seconds()).astype(int)
            g = d.groupby("sec")["duration_ms"].quantile(0.95)
            ax.plot(g.index, g.values, label=LABEL[t], linewidth=1.5)
        ax.set_xlabel("Tempo do teste (s)"); ax.set_ylabel("p95 do tempo de resposta (ms)")
        ax.set_title(f"Evolução temporal do p95 — {SCNLAB[s]}")
        ax.legend(title="Arquitetura"); ax.grid(alpha=0.3)
        fig.tight_layout(); fig.savefig(os.path.join(FIG, f"timeseries_{s}.png"), dpi=150); plt.close(fig)


def stat_tests(per_rep, metric="median_ms"):
    """Compara as arquiteturas usando a MÉTRICA-RESUMO POR REPETIÇÃO (§3.6: a unidade
    amostral é a repetição, n≈50 por grupo — não as requisições individuais).
    Verifica a normalidade com Shapiro-Wilk (por grupo) ANTES do teste não-paramétrico
    (Kruskal-Wallis global + Mann-Whitney par a par com correção de Bonferroni)."""
    lines = ["Comparação entre arquiteturas — tempo de resposta (mediana por repetição)",
             "Unidade amostral: repetição (métrica-resumo por execução), conforme a seção 3.6.",
             "Normalidade: Shapiro-Wilk por grupo | Comparação: Kruskal-Wallis + Mann-Whitney (Bonferroni)\n"]
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
            lines.append(f"    {LABEL[targets[i]]} vs {LABEL[targets[j]]}: "
                         f"p={min(pu*nb,1):.2e} (Bonferroni) | medianas das repetições "
                         f"{med_i:.1f} vs {med_j:.1f} ms")
        lines.append("")
    txt = "\n".join(lines)
    with open(os.path.join(TAB, "stats_tests.txt"), "w", encoding="utf-8") as f:
        f.write(txt)
    return txt


def owner_detail_comparison(alldf):
    """Compara SÓ a operação discriminante (ficha agregada owner+pets+visits).
    É onde o monolito (em processo) difere dos microsserviços (entre serviços)."""
    sub = alldf[alldf["op"] == "ownerDetail"]
    if sub.empty:
        return None
    rows = []
    for (t, s, rep), g in sub.groupby(["target", "scenario", "rep"]):
        d = g["duration_ms"].to_numpy()
        rows.append({"target": t, "scenario": s, "rep": rep,
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
            ax.bar(x + i * w, piv[t], w, yerr=cis[t].fillna(0), capsize=4, label=LABEL.get(t, t))
        ax.set_xticks(x + w * (len(targets) - 1) / 2)
        ax.set_xticklabels([SCNLAB[s] for s in SCN])
        ax.set_ylabel("p95 (ms)")
        ax.set_title("Ficha do owner (AGREGAÇÃO owner+pets+visits) — p95 por arquitetura\n"
                     "(resolução em processo × distribuída entre serviços/funções)")
        ax.legend(title="Arquitetura"); ax.grid(axis="y", alpha=0.3)
        fig.tight_layout(); fig.savefig(os.path.join(FIG, "bar_owner_detail_p95.png"), dpi=150); plt.close(fig)
    return sm


def scalability(alldf):
    """Curva de escalabilidade (throughput sob carga crescente) + ponto de saturação.
    Usa rampa e pico. O ponto de saturação é o maior throughput sustentado com taxa de
    erro abaixo do limiar (env SAT_ERR_THRESHOLD; padrão 2%). Reforça a hipótese H2."""
    thr_err = float(os.environ.get("SAT_ERR_THRESHOLD", "0.02"))
    rows = []
    for s in ["ramp", "spike"]:
        sub = alldf[alldf.scenario == s]
        targets = order_targets(sub.target.unique())
        if not targets:
            continue
        fig, ax = plt.subplots(figsize=(9, 5))
        for t in targets:
            d = sub[sub.target == t].copy()
            reps = max(d["rep"].nunique(), 1)
            d["sec"] = d.groupby("rep")["time"].transform(lambda x: (x - x.min()).dt.total_seconds()).astype(int)
            g = d.groupby("sec")
            thr = g.size() / reps  # throughput médio por segundo (entre repetições)
            err = g["failed"].mean().reindex(thr.index).fillna(0)
            ax.plot(thr.index, thr.values, label=LABEL[t], linewidth=1.5)
            ok = thr[err < thr_err]
            rows.append({
                "target": t, "scenario": s,
                "throughput_max_sustentavel_rps": round(float(ok.max()), 1) if len(ok) else float("nan"),
                "throughput_pico_rps": round(float(thr.max()), 1),
                "erro_max_pct": round(100 * float(err.max()), 2),
            })
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
    """Uso de CPU/memória por arquitetura (validação da equivalência — §3.4), lido de
    results/resources/usage.csv (gerado por cloudwatch-capture.ps1 na execução AWS).
    Pula silenciosamente se o arquivo não existir."""
    path = os.path.join(RESULTS, "resources", "usage.csv")
    if not os.path.exists(path):
        return None
    df = pd.read_csv(path)
    for c in ["cpu_avg_pct", "cpu_max_pct", "mem_avg_pct", "mem_max_pct"]:
        if c not in df.columns:
            df[c] = np.nan
    agg = df.groupby("architecture").agg(
        cpu_avg=("cpu_avg_pct", "mean"), cpu_max=("cpu_max_pct", "max"),
        mem_avg=("mem_avg_pct", "mean"), mem_max=("mem_max_pct", "max"),
    ).reset_index()
    agg.to_csv(os.path.join(TAB, "resource_usage.csv"), index=False)

    targets = [a for a in ["Monolito", "Microsserviços", "Serverless"] if a in set(agg.architecture)]
    sub = agg[agg.architecture.isin(targets)]
    if sub["cpu_avg"].notna().any():
        x = np.arange(len(sub)); w = 0.38
        fig, ax = plt.subplots(figsize=(7, 5))
        ax.bar(x - w / 2, sub["cpu_avg"], w, label="CPU")
        if sub["mem_avg"].notna().any():
            ax.bar(x + w / 2, sub["mem_avg"], w, label="Memória")
        ax.set_xticks(x); ax.set_xticklabels(sub["architecture"])
        ax.set_ylabel("Utilização média (%)")
        ax.set_title("Uso de recursos por arquitetura (validação da equivalência)")
        ax.legend(); ax.grid(axis="y", alpha=0.3)
        fig.tight_layout(); fig.savefig(os.path.join(FIG, "resource_usage.png"), dpi=150); plt.close(fig)
    return agg


def main():
    alldf = load_all()
    per_rep = per_rep_metrics(alldf)
    summary = summarize(per_rep)

    per_rep.to_csv(os.path.join(TAB, "per_rep.csv"), index=False)
    summary.to_csv(os.path.join(TAB, "summary.csv"), index=False)

    grouped_bar(summary, "p95_ms", "p95 (ms)", "Tempo de resposta (p95) por arquitetura", "bar_p95.png")
    grouped_bar(summary, "p99_ms", "p99 (ms)", "Tempo de resposta (p99) por arquitetura", "bar_p99.png")
    grouped_bar(summary, "throughput_rps", "Throughput (req/s)", "Throughput por arquitetura", "bar_throughput.png")
    grouped_bar(summary, "error_rate_pct", "Taxa de erro (%)", "Taxa de erro por arquitetura", "bar_error.png")
    boxplots(alldf); ecdf(alldf); timeseries(alldf)
    sat = scalability(alldf)
    res = resource_usage()
    od = owner_detail_comparison(alldf)
    tests = stat_tests(per_rep)

    pd.set_option("display.width", 160, "display.max_columns", 30)
    show = summary[["target", "scenario", "reps", "throughput_rps_mean",
                    "error_rate_pct_mean", "p95_ms_mean", "p99_ms_mean"]].round(2)
    print("\n=== Resumo por arquitetura × cenário (TODAS as requisições) ===")
    print(show.to_string(index=False))
    if od is not None:
        print("\n=== Operação DISCRIMINANTE: ficha agregada (ownerDetail) ===")
        print(od.round(2).to_string(index=False))
    if not sat.empty:
        print("\n=== Escalabilidade: ponto de saturação (throughput sustentável, erro<2%) ===")
        print(sat.to_string(index=False))
    if res is not None:
        print("\n=== Uso de recursos (CPU/memória, %) por arquitetura ===")
        print(res.round(1).to_string(index=False))
    print("\n=== Testes estatísticos ===\n" + tests)
    print(f"Figuras em {FIG}/ | Tabelas em {TAB}/")


if __name__ == "__main__":
    main()
