"""
Modelo de custo das três arquiteturas na AWS (us-east-1) — seção 3.6 da monografia.

Premissa: EC2/Fargate custam por TEMPO (independem da carga) e o Lambda por USO —
logo, a arquitetura mais econômica depende do perfil de tráfego. O modelo produz:
  1. custo mensal × volume, com banda de sensibilidade e break-even como FAIXA
     (duração cobrada p50/p95 × sob demanda vs descontos por compromisso);
  2. custo por milhão de requisições (curva — depende do volume pela parcela fixa);
  3. custo-eficiência: custo mensal por req/s sustentado no ponto de saturação, nas
     três arquiteturas (lê analysis/tables/saturation.csv se existir), e a comparação
     entre paridade de capacidade e paridade de custo;
  4. mapa de decisão: taxa ativa × fração ativa do mês -> arquitetura mais barata;
  5. decomposição do custo serverless por milhão de requisições (cold × snap).

NÃO chama a AWS: modelagem a partir de preços públicos + uso medido, ambos
parametrizáveis. A duração COBRADA (Billed Duration) vem da captura de cold start
(analysis/tables/coldstart_summary.csv, colunas billed_*) ou de variáveis de
ambiente. Atualizar preços/descontos na data da análise (fontes na Tabela de
preços da monografia, seção 3.6).

Uso:  python analysis/cost-model.py [results_dir] [output_dir]
      LAMBDA_BILLED_WARM_S=0.05 COLD_FRACTION=0.01 python analysis/cost-model.py
"""
import os
import sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RES = sys.argv[1] if len(sys.argv) > 1 else "results"
OUT = sys.argv[2] if len(sys.argv) > 2 else "analysis"
FIG, TAB = os.path.join(OUT, "figures"), os.path.join(OUT, "tables")
os.makedirs(FIG, exist_ok=True)
os.makedirs(TAB, exist_ok=True)

HOURS_MONTH = 730

SUBORDER = ["sem-otim", "snapstart"]
SUBLAB = {"sem-otim": "sem otimização", "snapstart": "SnapStart"}
SUBCOLOR = {"sem-otim": "tab:green", "snapstart": "tab:purple"}

# --- Preços us-east-1 (USD), verificados em 28 ago. 2026 na AWS Price List API ---
P = {
    "ec2_c5_large_hr": 0.085,       # monolito (c5.large, 2 vCPU/4 GB)
    "ec2_m5_large_hr": 0.096,       # MySQL (m5.large, 2 vCPU/8 GB)
    "fargate_vcpu_hr": 0.04048,
    "fargate_gb_hr": 0.004445,
    "alb_hr": 0.0225,
    "alb_lcu_hr": 0.008,            # por LCU-hora
    "lambda_req": 0.20 / 1_000_000,
    "lambda_gb_s": 0.0000166667,
    "apigw_req": 1.00 / 1_000_000,  # API Gateway HTTP (até 300 M/mês)
}

# Fatores de desconto por compromisso sobre o preço sob demanda (compute apenas),
# sempre na forma SEM ADIANTAMENTO: RI padrão para EC2 (fator do c5.large; o do
# m5.large difere menos de um ponto percentual) e Compute Savings Plans para Fargate.
# O desconto do Lambda via Compute Savings Plans (~17%) é ignorado: simplificação
# conservadora CONTRA o serverless no break-even.
PRICING_MODES = {
    "on-demand": {"ec2": 1.000, "fargate": 1.00},
    "ri-1y":     {"ec2": 0.635, "fargate": 0.80},
    "ri-3y":     {"ec2": 0.424, "fargate": 0.55},
}

# --- Dimensionamento (Quadro 2) ---
FARGATE_VCPU, FARGATE_GB = 2.0, 4.0       # soma das 6 tarefas
LAMBDA_MEM_GB = 1769 / 1024               # ≈ 1 vCPU/invocação

# --- Uso medido (preencher com a AWS; env sobrepõe o CSV) ---
ENV = os.environ.get
BILLED_WARM_S = float(ENV("LAMBDA_BILLED_WARM_S", "0.05"))   # mediana cobrada (warm)
BILLED_P95_S = float(ENV("LAMBDA_BILLED_P95_S", "0.15"))     # p95 cobrado
COLD_FRACTION = float(ENV("COLD_FRACTION", "0.01"))          # f_fria no tráfego real
# A f_fria medida vale para o perfil de tráfego do experimento (VUs subindo do zero).
# Projetar custo mensal para outros volumes exige tratá-la como faixa declarada.
COLD_FRACTION_SENS = [float(x) for x in ENV("COLD_FRACTION_SENS", "0.0001,0.01,0.10").split(",")]
COLD_EXTRA_S = float(ENV("COLD_EXTRA_S", "2.0"))             # d_extra por invocação fria
AVG_RESP_KB = float(ENV("AVG_RESP_KB", "5"))                 # p/ dimensão de bytes da LCU
# Dias (UTC) em que a campanha definitiva rodou. Sem esta lista a atribuição por
# arquitetura soma o período inteiro do CSV, que inclui ensaios e execuções
# descartadas, e superestima o braço que mais consumiu.
CAMPAIGN_DAYS = [d.strip() for d in ENV("BILLING_CAMPAIGN_DAYS", "").split(",") if d.strip()]

# O MySQL é compartilhado pelas três (sempre ligado) — custo COMUM.
MYSQL_MONTH = P["ec2_m5_large_hr"] * HOURS_MONTH


def load_coldstart_measured():
    """Sobrepõe os defaults com a captura real (billed_*), se disponível."""
    path = os.path.join(TAB, "coldstart_summary.csv")
    if not os.path.exists(path):
        return {}
    df = pd.read_csv(path)
    out = {}
    for _, r in df.iterrows():
        # o summary usa rótulos legíveis ("Sem otimização"/"SnapStart") — normaliza
        sub = "snapstart" if "snap" in str(r["subscenario"]).lower() else "sem-otim"
        warm = r.get("billed_warm_med_ms", np.nan)
        cold = r.get("billed_cold_med_ms", np.nan)
        p95 = r.get("billed_warm_p95_ms", np.nan)
        if pd.notna(warm) and pd.notna(cold):
            out[sub] = {"warm_s": warm / 1000.0, "extra_s": max(cold - warm, 0) / 1000.0}
            if pd.notna(p95):
                out[sub]["warm_p95_s"] = p95 / 1000.0
        elif pd.notna(r.get("init_cold_med_ms", np.nan)):
            # fallback: INIT tarifado ≈ acréscimo cobrado no cold
            out[sub] = {"warm_s": BILLED_WARM_S, "extra_s": r["init_cold_med_ms"] / 1000.0}
    return out


def load_cold_fraction():
    """f_fria observada na janela dos testes (cloudwatch-capture.ps1), por subcenário."""
    path = os.path.join(RES, "resources", "lambda_cold_fraction.csv")
    if not os.path.exists(path):
        return {}
    df = pd.read_csv(path)
    return {str(r["subscenario"]).strip(): float(r["cold_fraction"])
            for _, r in df.iterrows() if pd.notna(r.get("cold_fraction", np.nan))}


def load_avg_resp_kb(arm="micro"):
    """Tamanho médio de resposta (KB/req) dos summaries do k6 — dimensão de bytes da LCU.

    Lê só o braço dos microsserviços: o ALB existe apenas nele, e a listagem dos
    microsserviços não embute as visitas, então trafega cerca de um décimo do corpo
    dos outros braços. A média dos três multiplicaria por nove a parcela de bytes da
    LCU de um balanceador que só um deles paga."""
    import glob as _glob
    import json as _json
    total_bytes, total_reqs = 0.0, 0.0
    for p in _glob.glob(os.path.join(RES, arm, "*", "*-summary.json")):
        try:
            with open(p, encoding="utf-8") as f:
                m = _json.load(f).get("metrics", {})
            total_bytes += m.get("data_received", {}).get("count", 0)
            total_reqs += m.get("http_reqs", {}).get("count", 0)
        except (OSError, ValueError):
            continue
    return (total_bytes / total_reqs / 1024.0) if total_reqs > 0 else None


def apply_measured_overrides(measured):
    """Medições reais sobrepõem os defaults — mas a env explícita sempre vence."""
    global BILLED_WARM_S, BILLED_P95_S, COLD_FRACTION, COLD_EXTRA_S, AVG_RESP_KB
    ref = measured.get("sem-otim") or measured.get("snapstart")
    if ref:
        if "LAMBDA_BILLED_WARM_S" not in os.environ:
            BILLED_WARM_S = ref["warm_s"]
        if "LAMBDA_BILLED_P95_S" not in os.environ and "warm_p95_s" in ref:
            BILLED_P95_S = ref["warm_p95_s"]
        if "COLD_EXTRA_S" not in os.environ:
            COLD_EXTRA_S = ref["extra_s"]
    frac = load_cold_fraction()
    if frac and "COLD_FRACTION" not in os.environ:
        COLD_FRACTION = frac.get("sem-otim", next(iter(frac.values())))
    if "AVG_RESP_KB" not in os.environ:
        kb = load_avg_resp_kb()
        if kb:
            AVG_RESP_KB = kb
    return frac


def lcu_units(rps):
    """Estimativa de LCU no período ativo: máx. entre conexões novas e bytes
    processados; as dimensões de conexões ativas e de regras são dominadas por essas
    nos cenários do experimento. Assume 1 conexão nova por requisição — o gerador
    reusa conexões, então é hipótese conservadora CONTRA os microsserviços."""
    new_conn = rps / 25.0
    gb_hour = rps * 3600 * AVG_RESP_KB / 1e6
    return max(new_conn, gb_hour / 1.0)


def cost(req_month, mode="on-demand", warm_s=None, f_cold=None, extra_s=None,
         active_frac=1.0, include_db=True):
    """Custo mensal (USD) por arquitetura. `active_frac` afeta só a LCU (as
    parcelas de tempo das contínuas independem da atividade; o serverless
    depende apenas de req_month). `include_db=False` remove o piso comum do SGBD,
    que domina o custo por requisição em volume baixo e achata a comparação."""
    d = PRICING_MODES[mode]
    warm_s = BILLED_WARM_S if warm_s is None else warm_s
    f_cold = COLD_FRACTION if f_cold is None else f_cold
    extra_s = COLD_EXTRA_S if extra_s is None else extra_s
    db = MYSQL_MONTH if include_db else 0.0

    mono = P["ec2_c5_large_hr"] * d["ec2"] * HOURS_MONTH + db

    active_h = HOURS_MONTH * active_frac
    rps_active = req_month / (active_h * 3600) if active_h > 0 else 0.0
    fargate = ((FARGATE_VCPU * P["fargate_vcpu_hr"] + FARGATE_GB * P["fargate_gb_hr"])
               * d["fargate"] * HOURS_MONTH
               + P["alb_hr"] * HOURS_MONTH
               + P["alb_lcu_hr"] * lcu_units(rps_active) * active_h
               + db)

    billed_s = warm_s + f_cold * extra_s          # d_cobr = d_quente + f_fria*d_extra
    gb_s = LAMBDA_MEM_GB * billed_s * req_month
    serverless = (req_month * (P["lambda_req"] + P["apigw_req"])
                  + gb_s * P["lambda_gb_s"] + db)
    return {"Monolito": mono, "Microsserviços": fargate, "Serverless": serverless}


def breakeven(reqs, srv, cont):
    diff = srv - cont
    idx = np.where(np.diff(np.sign(diff)) != 0)[0]
    return reqs[idx[0]] if len(idx) else None


def subscenario_params(measured):
    """warm/extra por subcenário, com defaults quando a captura ainda não existe
    (SnapStart: acréscimo ~10x menor)."""
    out = {}
    for k in SUBORDER:
        v = measured.get(k)
        out[k] = v if v is not None else {
            "warm_s": BILLED_WARM_S,
            "extra_s": COLD_EXTRA_S if k == "sem-otim" else COLD_EXTRA_S / 10,
        }
    return out


def fig_breakeven_band(reqs, subs, frac):
    """Curvas de custo com banda de sensibilidade + faixa de break-even. Os dois
    subcenários serverless aparecem como curvas próprias: o SnapStart é objetivo
    específico do trabalho e não pode ficar fora da figura principal de custo."""
    fig, ax = plt.subplots(figsize=(9, 5))
    rows = []
    curves = {}
    for k, v in subs.items():
        f = frac.get(k, COLD_FRACTION)
        lo = np.array([cost(r, warm_s=v["warm_s"], f_cold=f, extra_s=v["extra_s"])["Serverless"] for r in reqs])
        hi = np.array([cost(r, warm_s=v.get("warm_p95_s", BILLED_P95_S), f_cold=f, extra_s=v["extra_s"])["Serverless"]
                       for r in reqs])
        ax.fill_between(reqs, lo, hi, alpha=0.20, color=SUBCOLOR[k])
        ax.plot(reqs, lo, color=SUBCOLOR[k], linewidth=1.4,
                label=f"Serverless — {SUBLAB[k]} (p50–p95)")
        curves[k] = (lo, hi)

    for arch, color in [("Monolito", "tab:blue"), ("Microsserviços", "tab:orange")]:
        for mode, ls in [("on-demand", "-"), ("ri-3y", "--")]:
            c = np.array([cost(r, mode=mode)[arch] for r in reqs])
            ax.plot(reqs, c, ls, color=color, linewidth=1.6,
                    label=f"{arch} ({mode})")
            for k, (lo, hi) in curves.items():
                for d_label, srv in [("p50", lo), ("p95", hi)]:
                    be = breakeven(reqs, srv, c)
                    rows.append({"subcenario": SUBLAB[k], "arquitetura": arch, "preco": mode,
                                 "duracao": d_label,
                                 "breakeven_req_mes": None if be is None else round(be)})
    ax.set_xscale("log")
    ax.set_xlabel("Requisições por mês")
    ax.set_ylabel("Custo mensal estimado (USD)")
    ax.set_title("Custo × volume, com sensibilidade (us-east-1)")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3, which="both")
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "cost_sensitivity.png"), dpi=150)
    plt.close(fig)

    be = pd.DataFrame(rows)
    be.to_csv(os.path.join(TAB, "cost_breakeven_range.csv"), index=False)
    return be


def fig_per_million(reqs):
    """Com e sem o piso comum do SGBD: incluído, ele domina em volume baixo e faz as
    três curvas coincidirem, escondendo a diferença entre as arquiteturas."""
    fig, ax = plt.subplots(figsize=(9, 5))
    for arch, color in [("Monolito", "tab:blue"), ("Microsserviços", "tab:orange"),
                        ("Serverless", "tab:green")]:
        tot = np.array([cost(r)[arch] / r * 1e6 for r in reqs])
        exd = np.array([cost(r, include_db=False)[arch] / r * 1e6 for r in reqs])
        ax.plot(reqs, tot, "-", color=color, linewidth=1.8, label=f"{arch} (com SGBD)")
        ax.plot(reqs, exd, ":", color=color, linewidth=1.4, label=f"{arch} (sem SGBD)")
    ax.set_xscale("log"); ax.set_yscale("log")
    ax.set_xlabel("Requisições por mês")
    ax.set_ylabel("Custo por milhão de requisições (USD)")
    ax.set_title("Custo por requisição × volume")
    ax.legend(fontsize=8); ax.grid(alpha=0.3, which="both")
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "cost_per_million.png"), dpi=150)
    plt.close(fig)


def fig_decision_map():
    """Taxa média no período ativo × fração ativa do mês -> mais barata."""
    rates = np.logspace(-1, 3, 120)          # 0,1 a 1000 req/s no período ativo
    fracs = np.linspace(0.01, 1.0, 100)      # fração ativa do mês
    archs = ["Monolito", "Microsserviços", "Serverless"]
    grid = np.zeros((len(fracs), len(rates)), dtype=int)
    for i, f in enumerate(fracs):
        for j, r in enumerate(rates):
            v = r * 3600 * HOURS_MONTH * f
            c = cost(v, active_frac=f)
            grid[i, j] = int(np.argmin([c[a] for a in archs]))
    fig, ax = plt.subplots(figsize=(9, 5))
    cmap = matplotlib.colors.ListedColormap(["#aec7e8", "#ffbb78", "#98df8a"])
    ax.pcolormesh(rates, fracs, grid, cmap=cmap, vmin=0, vmax=2, shading="auto")
    ax.set_xscale("log")
    ax.set_xlabel("Taxa média no período ativo (req/s)")
    ax.set_ylabel("Fração ativa do mês")
    ax.set_title("Arquitetura mais barata por perfil de tráfego")
    handles = [plt.Rectangle((0, 0), 1, 1, color=c)
               for c in ["#aec7e8", "#ffbb78", "#98df8a"]]
    ax.legend(handles, archs, loc="upper left", fontsize=8)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "cost_decision_map.png"), dpi=150)
    plt.close(fig)


def fig_breakdown(subs, frac):
    """Decomposição do custo serverless por milhão de req, cold × snap."""
    labels, req_c, gw_c, gbs_warm, gbs_cold = [], [], [], [], []
    for k, v in subs.items():
        f_sub = frac.get(k, COLD_FRACTION)  # f_fria medida por subcenário, se houver
        labels.append(SUBLAB[k].capitalize())
        req_c.append(0.20)
        gw_c.append(1.00)
        gbs_warm.append(LAMBDA_MEM_GB * v["warm_s"] * P["lambda_gb_s"] * 1e6)
        gbs_cold.append(LAMBDA_MEM_GB * f_sub * v["extra_s"] * P["lambda_gb_s"] * 1e6)
    x = np.arange(len(labels))
    fig, ax = plt.subplots(figsize=(7, 5))
    bottom = np.zeros(len(labels))
    for vals, lab, color in [(req_c, "Requisições Lambda", "#1f77b4"),
                             (gw_c, "API Gateway", "#ff7f0e"),
                             (gbs_warm, "GB-s (warm)", "#2ca02c"),
                             (gbs_cold, "GB-s (cold extra)", "#d62728")]:
        ax.bar(x, vals, 0.5, bottom=bottom, label=lab, color=color)
        bottom += np.array(vals)
    ax.set_xticks(x); ax.set_xticklabels(labels)
    ax.set_ylabel("USD por milhão de requisições")
    ax.set_title(f"Custo serverless por componente (f_fria={COLD_FRACTION:.0%})")
    ax.legend(); ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "cost_breakdown_serverless.png"), dpi=150)
    plt.close(fig)


def table_breakeven_sensitivity(reqs, subs, frac):
    """Break-even em função da f_fria: a medida corresponde ao perfil de tráfego do
    experimento e não se transporta para volumes arbitrários."""
    rows = []
    for k, v in subs.items():
        vals = sorted(set(COLD_FRACTION_SENS) | ({frac[k]} if k in frac else set()))
        for f in vals:
            srv = np.array([cost(r, warm_s=v["warm_s"], f_cold=f, extra_s=v["extra_s"])["Serverless"]
                            for r in reqs])
            for arch in ("Monolito", "Microsserviços"):
                for mode in PRICING_MODES:
                    be = breakeven(reqs, srv, np.array([cost(r, mode=mode)[arch] for r in reqs]))
                    rows.append({"subcenario": SUBLAB[k], "f_fria": f,
                                 "medida": bool(k in frac and abs(f - frac[k]) < 1e-12),
                                 "arquitetura": arch, "preco": mode,
                                 "breakeven_req_mes": None if be is None else round(be)})
    df = pd.DataFrame(rows)
    df.to_csv(os.path.join(TAB, "cost_breakeven_sensitivity.csv"), index=False)
    return df


def table_capacity_vs_cost():
    """Paridade de capacidade nominal não é paridade de custo: fixar 2 vCPU/4 GB nos
    dois lados dá aos microsserviços um orçamento financeiro maior. Exclui o SGBD, que
    é comum, para isolar a parcela de computação."""
    mono = P["ec2_c5_large_hr"] * HOURS_MONTH
    farg = (FARGATE_VCPU * P["fargate_vcpu_hr"] + FARGATE_GB * P["fargate_gb_hr"]) * HOURS_MONTH
    alb = P["alb_hr"] * HOURS_MONTH
    rows = [("Monolito (c5.large)", "2 vCPU / 4 GB", mono),
            ("Microsserviços (Fargate)", "2 vCPU / 4 GB", farg),
            ("Microsserviços + ALB", "2 vCPU / 4 GB + balanceador", farg + alb)]
    df = pd.DataFrame([{"arquitetura": a, "capacidade_contratada": c,
                        "usd_mes": round(v, 2), "vs_monolito_pct": round(100 * (v / mono - 1), 1)}
                       for a, c, v in rows])
    df.to_csv(os.path.join(TAB, "capacity_vs_cost.csv"), index=False)
    return df


def table_efficiency(subs, frac):
    """Custo mensal por req/s sustentado (E_a = C_a / X*_a) — usa saturation.csv.
    Inclui o serverless: sem capacidade contratada, o denominador é a vazão sustentada
    no pico e o numerador, o custo do volume que essa vazão implica em um mês."""
    path = os.path.join(TAB, "saturation.csv")
    if not os.path.exists(path):
        print("[custo-eficiência] saturation.csv ainda não existe — pulado "
              "(rode analysis/analyze.py com os resultados da Fase 7).")
        return None
    sat = pd.read_csv(path)
    col = "throughput_max_sustentavel_rps"
    if col not in sat.columns or "target" not in sat.columns:
        print(f"[custo-eficiência] colunas esperadas ausentes em {path} — pulado.")
        return None
    # Vazão útil quando houver: sob estresse o disjuntor dos microsserviços responde
    # 200 com a ficha vazia, e dividir o custo por uma capacidade que inclui essas
    # respostas faria a arquitetura parecer mais barata por trabalho entregue.
    if "vazao_util_max_rps" in sat.columns:
        sat[col] = sat["vazao_util_max_rps"].fillna(sat[col])
    xstar = sat.groupby("target")[col].max()
    base = cost(1e6)  # parcela fixa domina; volume irrelevante p/ contínuas
    rows = []
    for tgt, arch in (("mono", "Monolito"), ("micro", "Microsserviços")):
        match = [t for t in xstar.index if str(t) == tgt]
        if match:
            x = float(xstar[match[0]])
            rows.append({"arquitetura": arch, "throughput_sustentado_rps": round(x, 1),
                         "custo_mensal_usd": round(base[arch], 2),
                         "usd_mes_por_rps": round(base[arch] / x, 2) if x else np.nan})
    for tgt, k in (("serverless-cold", "sem-otim"), ("serverless-snap", "snapstart")):
        if tgt not in xstar.index or k not in subs:
            continue
        x = float(xstar[tgt])
        if not x or np.isnan(x):
            continue
        v = x * 3600 * HOURS_MONTH
        c = cost(v, warm_s=subs[k]["warm_s"], f_cold=frac.get(k, COLD_FRACTION),
                 extra_s=subs[k]["extra_s"])["Serverless"]
        rows.append({"arquitetura": f"Serverless ({SUBLAB[k]})",
                     "throughput_sustentado_rps": round(x, 1),
                     "custo_mensal_usd": round(c, 2), "usd_mes_por_rps": round(c / x, 2)})
    if not rows:
        return None
    eff = pd.DataFrame(rows)
    eff.to_csv(os.path.join(TAB, "cost_efficiency.csv"), index=False)
    return eff


# Tipos de uso do Cost Explorer que correspondem a um preço da Tabela 3, e o braço a
# que pertencem. O SGBD entra à parte por ser piso comum às três (seção 3.6).
BILLING_MAP = {
    "BoxUsage:c5.large":              ("Monolito", "ec2_c5_large_hr"),
    "USE1-Fargate-vCPU-Hours:perCPU": ("Microsserviços", "fargate_vcpu_hr"),
    "USE1-Fargate-GB-Hours":          ("Microsserviços", "fargate_gb_hr"),
    "LoadBalancerUsage":              ("Microsserviços", "alb_hr"),
    "LCUUsage":                       ("Microsserviços", "alb_lcu_hr"),
    "Lambda-GB-Second":               ("Serverless", "lambda_gb_s"),
    "Request":                        ("Serverless", "lambda_req"),
    "USE1-ApiGatewayHttpRequest":     ("Serverless", "apigw_req"),
    "BoxUsage:m5.large":              ("SGBD (comum)", "ec2_m5_large_hr"),
}
# Fora do modelo por decisão declarada na seção 3.6, com o motivo de cada exclusão.
BILLING_FORA = {
    "DataTransfer-Out-Bytes": "transferência de dados",
    "DataTransfer-Regional-Bytes": "transferência de dados",
    "BoxUsage:c5.xlarge": "gerador de carga (aparato)",
    "USE1-VendedLog-Bytes": "observabilidade",
    "EBS:VolumeUsage.gp3": "armazenamento",
    "Requests-Tier1": "armazenamento",
    "Requests-Tier2": "armazenamento",
    "USE1-PublicIPv4:InUseAddress": "endereçamento IPv4 público",
    "USE1-PublicIPv4:IdleAddress": "endereçamento IPv4 público",
    "USE1-APIRequest": "consultas ao próprio Cost Explorer",
}


def billing_validation():
    """Confronta o modelo com a fatura (§3.6), a partir de billing-capture.ps1.

    Divide o custo faturado pela quantidade faturada para obter o preço unitário
    efetivamente cobrado, que é o que se compara à Tabela 3. Um preço abaixo do
    tabelado indica franquia gratuita no período, e não erro do modelo."""
    path = os.path.join(RES, "resources", "billing-usage-type.csv")
    if not os.path.exists(path):
        print("[fatura] billing-usage-type.csv ainda não existe — pulado "
              "(rode analysis/billing-capture.ps1).")
        return None, None
    try:
        df = pd.read_csv(path)
    except (OSError, ValueError):
        return None, None
    if "usage_type" not in df.columns:
        return None, None
    g = df.groupby("usage_type").agg(custo_usd=("custo_usd", "sum"),
                                     quantidade=("quantidade", "sum"),
                                     unidade=("unidade", "first")).reset_index()

    val = []
    for _, r in g.iterrows():
        m = BILLING_MAP.get(r["usage_type"])
        if not m or not r["quantidade"]:
            continue
        arq, chave = m
        p_mod, p_fat = P[chave], r["custo_usd"] / r["quantidade"]
        dev = 100 * (p_fat - p_mod) / p_mod if p_mod else np.nan
        val.append({"item": r["usage_type"], "arquitetura": arq, "unidade": r["unidade"],
                    "preco_modelo_usd": p_mod, "preco_faturado_usd": round(p_fat, 12),
                    "desvio_pct": round(dev, 3), "quantidade": r["quantidade"],
                    "custo_usd": round(r["custo_usd"], 4),
                    "obs": "franquia gratuita no período" if dev < -1 else ""})
    val = pd.DataFrame(val).sort_values("custo_usd", ascending=False)
    val.to_csv(os.path.join(TAB, "billing_validation.csv"), index=False)

    # A atribuição por arquitetura, ao contrário da validação de preços, depende de
    # QUANDO cada braço rodou: o CSV cobre todo o período capturado.
    dias = df[df["data"].isin(CAMPAIGN_DAYS)] if CAMPAIGN_DAYS else df
    gd = dias.groupby("usage_type")["custo_usd"].sum()
    braco = []
    for ut, custo in gd.items():
        m = BILLING_MAP.get(ut)
        rot = m[0] if m else f"fora do modelo: {BILLING_FORA.get(ut, 'outros')}"
        braco.append({"rotulo": rot, "custo_usd": custo})
    bd = pd.DataFrame(braco).groupby("rotulo")["custo_usd"].sum().reset_index()

    # O dia do braço serverless mistura a campanha definitiva com a que foi descartada,
    # e as duas não são separáveis pelo Cost Explorer sem granularidade horária, que é
    # opt-in da conta pagadora. Substitui-se, então, o valor faturado pela quantidade
    # medida no CloudWatch, avaliada aos mesmos preços unitários já conferidos acima.
    med = _lambda_medido()
    if med is not None:
        inv, gbs = med
        bd = bd[bd["rotulo"] != "Serverless"]
        bd = pd.concat([bd, pd.DataFrame([{
            "rotulo": "Serverless",
            "custo_usd": gbs * P["lambda_gb_s"] + inv * (P["lambda_req"] + P["apigw_req"])}])],
            ignore_index=True)
    bd["custo_usd"] = bd["custo_usd"].round(4)
    bd = bd.sort_values("custo_usd", ascending=False).reset_index(drop=True)
    bd["pct_do_uso"] = (100 * bd["custo_usd"] / bd["custo_usd"].sum()).round(1)

    # As linhas não têm o mesmo escopo, e tratá-las como iguais atribuiria à campanha um
    # consumo que não foi dela: o SGBD e as parcelas fora do modelo ficaram de pé durante
    # todas as execuções, inclusive a descartada.
    def _escopo(rot):
        if not CAMPAIGN_DAYS:
            return "período completo do CSV"
        if rot == "Serverless":
            return "medido no CloudWatch (só a definitiva)"
        if rot in ("Monolito", "Microsserviços"):
            return "dia do braço (só a definitiva)"
        return "dias da campanha (inclui execuções descartadas)"

    bd["escopo"] = bd["rotulo"].map(_escopo)
    bd.to_csv(os.path.join(TAB, "billing_by_arm.csv"), index=False)
    return val, bd


def _lambda_medido():
    """Invocações e GB-segundo do braço serverless na campanha, do CloudWatch."""
    path = os.path.join(RES, "resources", "lambda-invocacoes-por-funcao.csv")
    if not os.path.exists(path):
        return None
    try:
        d = pd.read_csv(path)
    except (OSError, ValueError):
        return None
    if "duracao_soma_ms" not in d.columns:
        return None
    return float(d["invocacoes"].sum()), float((d["duracao_soma_ms"] / 1000 * (d["memoria_mb"] / 1024)).sum())


def main():
    measured = load_coldstart_measured()
    frac = apply_measured_overrides(measured)
    reqs = np.logspace(5, 9, 300)  # 100 mil a 1 bilhão de req/mês

    par = pd.DataFrame([
        {"parametro": "d_quente (mediana cobrada)", "valor": round(BILLED_WARM_S, 4), "unidade": "s"},
        {"parametro": "d_quente (p95 cobrado)", "valor": round(BILLED_P95_S, 4), "unidade": "s"},
        {"parametro": "d_extra (acréscimo do cold)", "valor": round(COLD_EXTRA_S, 4), "unidade": "s"},
        {"parametro": "f_fria observada", "valor": COLD_FRACTION, "unidade": "fração"},
        {"parametro": "corpo médio (braço com ALB)", "valor": round(AVG_RESP_KB, 2), "unidade": "KB/req"},
    ])
    par.to_csv(os.path.join(TAB, "cost_model_params.csv"), index=False)
    print("=== Parâmetros medidos usados no modelo ===")
    print(par.to_string(index=False))

    subs = subscenario_params(measured)
    be = fig_breakeven_band(reqs, subs, frac)
    sens = table_breakeven_sensitivity(reqs, subs, frac)
    fig_per_million(reqs)
    fig_decision_map()
    fig_breakdown(subs, frac)
    eff = table_efficiency(subs, frac)
    cap = table_capacity_vs_cost()

    # tabela por perfil (volume × fração ativa)
    profiles = [
        ("baixo contínuo (1 req/s, 24/7)", 1, 1.00),
        ("médio contínuo (50 req/s, 24/7)", 50, 1.00),
        ("alto contínuo (500 req/s, 24/7)", 500, 1.00),
        ("médio comercial (50 req/s, 24% do mês)", 50, 0.24),
        ("picos esporádicos (100 req/s, 5% do mês)", 100, 0.05),
    ]
    rows = []
    for label, rps, f in profiles:
        v = rps * 3600 * HOURS_MONTH * f
        rows.append({"perfil": label, "req_mes": round(v),
                     **{a: round(c, 2) for a, c in cost(v, active_frac=f).items()}})
    tab = pd.DataFrame(rows)
    tab.to_csv(os.path.join(TAB, "cost_by_profile.csv"), index=False)

    pd.set_option("display.width", 170)
    print("=== Custo mensal estimado (USD) por perfil de tráfego ===")
    print(tab.to_string(index=False))
    print("\n=== Break-even serverless × contínuas (FAIXA de sensibilidade) ===")
    print(be.to_string(index=False))
    print("\n=== Break-even × f_fria (a medida vale para o perfil do experimento) ===")
    print(sens.to_string(index=False))
    print("\n=== Paridade de capacidade × paridade de custo (computação, sem SGBD) ===")
    print(cap.to_string(index=False))
    if eff is not None:
        print("\n=== Custo-eficiência (USD/mês por req/s sustentado) ===")
        print(eff.to_string(index=False))
    print("\nNotas: MySQL sempre ligado é custo COMUM às três (piso fixo) — não desloca o "
          "break-even nem o mapa de decisão, mas domina o custo por requisição em volume "
          "baixo. A tabela por perfil e o mapa de decisão usam o subcenário sem otimização "
          "(caso conservador). Os fatores de desconto foram conferidos na Price List API e "
          "nos Savings Plans (28 ago. 2026), sempre na forma sem adiantamento. A duração "
          "cobrada e a fração fria vêm da campanha, não dos defaults do script.")
    bval, barm = billing_validation()
    if bval is not None:
        print("\n=== Validação do modelo contra a fatura (§3.6) ===")
        print(bval[["item", "arquitetura", "preco_modelo_usd", "preco_faturado_usd",
                    "desvio_pct", "custo_usd", "obs"]].to_string(index=False))
        print("\n=== Custo faturado por arquitetura no período experimental ===")
        print(barm.to_string(index=False))
    print(f"Figuras em {FIG}/ | Tabelas em {TAB}/")


if __name__ == "__main__":
    main()
