"""
Análise de cold start × warm start do serverless (decisão 5 / §3.5).

Compara os DOIS subcenários (sem otimização × SnapStart) quanto ao tempo de
inicialização (Init Duration) e ao tempo de resposta em invocações a frio (cold)
e aquecidas (warm).

Entrada: CSV com colunas
  subscenario  -> sem-otim | snapstart
  invocation   -> cold | warm
  init_ms      -> Init Duration (só faz sentido no cold; 0/vazio no warm)
  duration_ms  -> duração do handler / tempo de resposta
Na AWS (Fase 7), esses valores saem da linha REPORT do CloudWatch Logs
(campos "Init Duration" e "Duration"); aqui o mesmo formato é reaproveitado.

Uso:
  python analysis/coldstart.py [measurements.csv] [output_dir]
"""
import os, sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy import stats

CSV = sys.argv[1] if len(sys.argv) > 1 else "results/coldstart/measurements.csv"
OUT = sys.argv[2] if len(sys.argv) > 2 else "analysis"
FIG, TAB = os.path.join(OUT, "figures"), os.path.join(OUT, "tables")
os.makedirs(FIG, exist_ok=True)
os.makedirs(TAB, exist_ok=True)

SUBLAB = {"sem-otim": "Sem otimização", "snapstart": "SnapStart"}
SUBORDER = ["sem-otim", "snapstart"]


def ci95(x):
    x = pd.Series(x).dropna().to_numpy()
    if len(x) < 2:
        return 0.0
    return float(stats.t.ppf(0.975, len(x) - 1) * x.std(ddof=1) / np.sqrt(len(x)))


def main():
    if not os.path.exists(CSV):
        sys.exit(f"Arquivo não encontrado: {CSV}\n"
                 f"Formato: subscenario,invocation,init_ms,duration_ms")
    df = pd.read_csv(CSV, comment="#")
    df["subscenario"] = df["subscenario"].str.strip()
    df["invocation"] = df["invocation"].str.strip()
    subs = [s for s in SUBORDER if s in set(df["subscenario"])]

    # --- Tabela-resumo ---
    rows = []
    for s in subs:
        cold = df[(df.subscenario == s) & (df.invocation == "cold")]
        warm = df[(df.subscenario == s) & (df.invocation == "warm")]
        rows.append({
            "subscenario": SUBLAB[s],
            "n_cold": len(cold), "n_warm": len(warm),
            "init_cold_med_ms": cold["init_ms"].median(),
            "init_cold_p95_ms": cold["init_ms"].quantile(0.95) if len(cold) else np.nan,
            "resp_cold_med_ms": cold["duration_ms"].median(),
            "resp_warm_med_ms": warm["duration_ms"].median(),
        })
    summary = pd.DataFrame(rows)
    summary.to_csv(os.path.join(TAB, "coldstart_summary.csv"), index=False)

    # --- Gráfico 1: Init Duration (cold) por subcenário ---
    means = [df[(df.subscenario == s) & (df.invocation == "cold")]["init_ms"].mean() for s in subs]
    cis = [ci95(df[(df.subscenario == s) & (df.invocation == "cold")]["init_ms"]) for s in subs]
    fig, ax = plt.subplots(figsize=(7, 5))
    bars = ax.bar([SUBLAB[s] for s in subs], means, yerr=cis, capsize=5,
                  color=["#d62728", "#2ca02c"][:len(subs)])
    ax.set_ylabel("Init Duration — cold start (ms)")
    ax.set_title("Inicialização a frio: sem otimização × SnapStart")
    ax.grid(axis="y", alpha=0.3)
    for b, m in zip(bars, means):
        ax.text(b.get_x() + b.get_width() / 2, m, f"{m:.0f} ms", ha="center", va="bottom")
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "coldstart_init.png"), dpi=150); plt.close(fig)

    # --- Gráfico 2: tempo de resposta cold × warm por subcenário ---
    x = np.arange(len(subs)); w = 0.35
    cold_med = [df[(df.subscenario == s) & (df.invocation == "cold")]["duration_ms"].median() for s in subs]
    warm_med = [df[(df.subscenario == s) & (df.invocation == "warm")]["duration_ms"].median() for s in subs]
    fig, ax = plt.subplots(figsize=(7, 5))
    ax.bar(x - w / 2, cold_med, w, label="Cold start", color="#d62728")
    ax.bar(x + w / 2, warm_med, w, label="Warm start", color="#1f77b4")
    ax.set_xticks(x); ax.set_xticklabels([SUBLAB[s] for s in subs])
    ax.set_ylabel("Tempo de resposta (ms, escala log)")
    ax.set_yscale("log")  # cold e warm diferem em ordens de grandeza
    ax.set_title("Tempo de resposta: cold × warm por subcenário")
    ax.legend(); ax.grid(axis="y", alpha=0.3, which="both")
    fig.tight_layout(); fig.savefig(os.path.join(FIG, "coldstart_cold_vs_warm.png"), dpi=150); plt.close(fig)

    # --- Saída ---
    pd.set_option("display.width", 160, "display.max_columns", 20)
    print("\n=== Cold start × warm start (por subcenário) ===")
    print(summary.round(1).to_string(index=False))
    print("\nNota de custo: desde ago/2025 a AWS tarifa a fase INIT; o Init Duration "
          "do cold start tem, portanto, impacto também de custo (discutir no Cap. 4).")
    print(f"\nFiguras em {FIG}/ | Tabela em {TAB}/coldstart_summary.csv")


if __name__ == "__main__":
    main()
