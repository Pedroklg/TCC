"""
Modelo de custo das três arquiteturas na AWS (us-east-1), em função do volume de
requisições mensal. Avalia a hipótese H4: custos de EC2/Fargate são por TEMPO
(independem da carga) e o de Lambda é por USO — logo, a arquitetura mais econômica
depende do perfil de tráfego. Identifica o ponto de equilíbrio (break-even).

NÃO chama a AWS: é uma modelagem a partir de preços públicos + uso medido (ambos
parametrizáveis). Atualize os preços e o uso (duração média do Lambda) com os valores
reais antes de usar no Capítulo 4.

Uso:  python analysis/cost-model.py
      LAMBDA_AVG_DUR_S=0.05 python analysis/cost-model.py
"""
import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = "analysis"
FIG, TAB = os.path.join(OUT, "figures"), os.path.join(OUT, "tables")
os.makedirs(FIG, exist_ok=True)
os.makedirs(TAB, exist_ok=True)

HOURS_MONTH = 730

# --- Preços us-east-1 (USD) — CONFERIR/ATUALIZAR ---
P = {
    "ec2_c5_large_hr": 0.085,       # monolito (c5.large, 2 vCPU/4 GB)
    "ec2_m5_large_hr": 0.096,       # MySQL (m5.large, 2 vCPU/8 GB)
    "fargate_vcpu_hr": 0.04048,
    "fargate_gb_hr": 0.004445,
    "alb_hr": 0.0225,
    "lambda_req": 0.20 / 1_000_000,     # por requisição
    "lambda_gb_s": 0.0000166667,        # por GB-s
    "apigw_req": 1.00 / 1_000_000,      # API Gateway HTTP por requisição
}

# --- Dimensionamento (Quadro 2) ---
FARGATE_VCPU, FARGATE_GB = 2.0, 4.0       # soma das 6 tarefas
LAMBDA_MEM_GB = 1769 / 1024               # ≈ 1 vCPU/invocação
# Uso medido (preencher com a AWS): duração média por invocação (s).
LAMBDA_AVG_DUR_S = float(os.environ.get("LAMBDA_AVG_DUR_S", "0.05"))

# O MySQL é compartilhado pelas três (sempre ligado) — custo COMUM.
MYSQL_MONTH = P["ec2_m5_large_hr"] * HOURS_MONTH


def cost(req_month):
    """Custo mensal (USD) de cada arquitetura para um volume de requisições."""
    mono = P["ec2_c5_large_hr"] * HOURS_MONTH + MYSQL_MONTH
    fargate = ((FARGATE_VCPU * P["fargate_vcpu_hr"] + FARGATE_GB * P["fargate_gb_hr"]) * HOURS_MONTH
               + P["alb_hr"] * HOURS_MONTH + MYSQL_MONTH)
    gb_s = LAMBDA_MEM_GB * LAMBDA_AVG_DUR_S * req_month
    serverless = (req_month * P["lambda_req"] + gb_s * P["lambda_gb_s"]
                  + req_month * P["apigw_req"] + MYSQL_MONTH)
    return {"Monolito": mono, "Microsserviços": fargate, "Serverless": serverless}


def main():
    # varre de 100 mil a 1 bilhão de requisições/mês (escala log)
    reqs = np.logspace(5, 9, 200)
    df = pd.DataFrame([cost(r) for r in reqs], index=reqs)

    # break-even: onde o serverless cruza cada arquitetura contínua
    crossings = {}
    for arch in ["Monolito", "Microsserviços"]:
        diff = (df["Serverless"] - df[arch]).values
        sign = np.sign(diff)
        idx = np.where(np.diff(sign) != 0)[0]
        crossings[arch] = reqs[idx[0]] if len(idx) else None

    # --- gráfico ---
    fig, ax = plt.subplots(figsize=(9, 5))
    for arch in ["Monolito", "Microsserviços", "Serverless"]:
        ax.plot(reqs, df[arch], label=arch, linewidth=1.8)
    for arch, x in crossings.items():
        if x:
            ax.axvline(x, color="gray", ls="--", alpha=0.5)
            ax.text(x, ax.get_ylim()[1] * 0.9, f"  break-even\n  {x:,.0f} req/mês",
                    fontsize=8, rotation=90, va="top")
    ax.set_xscale("log")
    ax.set_xlabel("Requisições por mês")
    ax.set_ylabel("Custo mensal estimado (USD)")
    ax.set_title("Custo por arquitetura × volume de tráfego (us-east-1)")
    ax.legend(title="Arquitetura")
    ax.grid(alpha=0.3, which="both")
    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "cost_breakeven.png"), dpi=150)
    plt.close(fig)

    # --- tabela em perfis representativos ---
    profiles = {"baixo (1 req/s)": 2.6e6, "médio (50 req/s)": 1.3e8, "alto (500 req/s)": 1.3e9}
    rows = [{"perfil": k, **{a: round(v, 2) for a, v in cost(r).items()}} for k, r in profiles.items()]
    tab = pd.DataFrame(rows)
    tab.to_csv(os.path.join(TAB, "cost_by_profile.csv"), index=False)

    pd.set_option("display.width", 160)
    print("=== Custo mensal estimado (USD) por perfil de tráfego ===")
    print(tab.to_string(index=False))
    print("\n=== Break-even (Serverless cruza a arquitetura contínua) ===")
    for arch, x in crossings.items():
        print(f"  Serverless × {arch}: {('%.0f req/mês' % x) if x else 'sem cruzamento na faixa'}")
    print("\nNota: o MySQL (sempre ligado) é custo COMUM às três — por isso o serverless "
          "também tem um piso fixo. Atualize preços e LAMBDA_AVG_DUR_S com os valores reais.")
    print(f"Figura: {FIG}/cost_breakeven.png | Tabela: {TAB}/cost_by_profile.csv")


if __name__ == "__main__":
    main()
