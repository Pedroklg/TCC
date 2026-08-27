"""Calibração do ponto de saturação (piloto, anterior à campanha definitiva).

Lê results/<alvo>/<ts>/calibration-rep01-raw.json e reconstrói, por patamar de taxa
de chegada, o throughput atingido, a taxa de erro e o p95. Daí saem o teto de cada
arquitetura e a taxa de pico a usar no cenário de estresse.

Como rodar: ver analysis/README.md.
"""
import json, glob, gzip, os, sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RESULTS = sys.argv[1] if len(sys.argv) > 1 else "results"
OUT = sys.argv[2] if len(sys.argv) > 2 else "analysis"
FIG, TAB = os.path.join(OUT, "figures"), os.path.join(OUT, "tables")
os.makedirs(FIG, exist_ok=True)
os.makedirs(TAB, exist_ok=True)

LABEL = {"mono": "Monolito", "micro": "Microsserviços",
         "serverless-cold": "Serverless (sem otim.)", "serverless-snap": "Serverless (SnapStart)"}
COLOR = {"mono": "tab:blue", "micro": "tab:orange",
         "serverless-cold": "tab:green", "serverless-snap": "tab:purple"}
# Traço e marcador distintos por série: a monografia é impressa, e a cor sozinha
# não separa as curvas em escala de cinza.
MARK = {"mono": "o", "micro": "s", "serverless-cold": "^", "serverless-snap": "D"}
DASH = {"mono": "-", "micro": "--", "serverless-cold": "-.", "serverless-snap": ":"}
ORDER = ["mono", "micro", "serverless-cold", "serverless-snap"]

plt.rcParams.update({"font.size": 12, "axes.titlesize": 12, "axes.labelsize": 12,
                     "legend.fontsize": 10, "xtick.labelsize": 11, "ytick.labelsize": 11})

BUCKET_S = int(os.environ.get("CALIB_BUCKET_S", "5"))
DROP_LEVEL = float(os.environ.get("CALIB_DROP_LEVEL", "0.10"))
PLATEAU = 0.95    # fração do throughput máximo que define o joelho
ERR_LEVEL = 5.0   # taxa de erro (%) cujo primeiro cruzamento também é reportado

WANTED = {"http_reqs", "http_req_failed", "http_req_duration", "iterations", "dropped_iterations"}


def _open(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, encoding="utf-8")


def load_run(path):
    """Agrega os Points do k6 em janelas de BUCKET_S segundos."""
    rows, t0 = {}, None
    with _open(path) as fh:
        for line in fh:
            if '"Point"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            m = o.get("metric")
            if o.get("type") != "Point" or m not in WANTED:
                continue
            d = o["data"]
            ts = pd.Timestamp(d["time"]).value / 1e9
            if t0 is None or ts < t0:
                t0 = ts
            rows.setdefault(m, []).append((ts, float(d["value"])))
    if not rows or t0 is None:
        return None

    out = {}
    for m, pts in rows.items():
        a = np.asarray(pts)
        b = ((a[:, 0] - t0) // BUCKET_S).astype(int)
        s = pd.Series(a[:, 1])
        if m == "http_req_duration":
            out["p95_ms"] = s.groupby(b).quantile(0.95)
        elif m == "http_req_failed":
            out["failed"] = s.groupby(b).sum()
            out["total"] = s.groupby(b).size()
        else:
            out[m] = s.groupby(b).sum()

    df = pd.DataFrame(out).fillna(0.0)
    df["achieved_rps"] = df.get("http_reqs", 0) / BUCKET_S
    df["iter_done_s"] = df.get("iterations", 0) / BUCKET_S
    df["dropped_s"] = df.get("dropped_iterations", 0) / BUCKET_S
    # O executor de modelo aberto tenta iniciar as iterações concluídas mais as
    # descartadas; a soma é a melhor estimativa da taxa oferecida de fato.
    df["offered_iter_s"] = df["iter_done_s"] + df["dropped_s"]
    df["error_pct"] = 100.0 * df["failed"] / df["total"].replace(0, np.nan)
    df["drop_frac"] = df["dropped_s"] / df["offered_iter_s"].replace(0, np.nan)
    reqs_per_iter = df["achieved_rps"].sum() / max(df["iter_done_s"].sum(), 1e-9)
    df["offered_rps"] = df["offered_iter_s"] * reqs_per_iter
    return df.reset_index(drop=True), reqs_per_iter


def to_levels(df):
    """Agrupa as janelas nos patamares de taxa (os degraus são geométricos)."""
    lv = df[df.offered_rps > 0].copy()
    if lv.empty:
        return lv
    # Arredondar a 2 algarismos significativos reúne as janelas de um mesmo degrau
    # sem depender do cronograma configurado no cenário.
    mag = np.floor(np.log10(lv.offered_rps))
    lv["level"] = (lv.offered_rps / 10 ** (mag - 1)).round() * 10 ** (mag - 1)
    g = lv.groupby("level").agg(
        offered_rps=("offered_rps", "median"),
        achieved_rps=("achieved_rps", "median"),
        error_pct=("error_pct", "median"),
        p95_ms=("p95_ms", "median"),
        drop_frac=("drop_frac", "median"),
        janelas=("achieved_rps", "size"),
    ).reset_index(drop=True)
    return g[g.janelas >= 2].sort_values("offered_rps")


def saturation(g):
    """Joelho da curva: menor taxa oferecida que já entrega PLATEAU do teto."""
    if g.empty:
        return {}
    peak = g.achieved_rps.max()
    knee = g[g.achieved_rps >= PLATEAU * peak].offered_rps.min()
    over = g[g.error_pct >= ERR_LEVEL]
    # Descarte de iterações não distingue, sozinho, alvo lento de teto de VUs: em
    # modelo aberto ambos impedem o início de novas iterações. Serve como indício
    # de saturação, e a distinção exige vus_max e client-cpu.csv da mesma bateria.
    drops = g[g.drop_frac.fillna(0) >= DROP_LEVEL]
    return {
        "teto_rps": round(peak, 1),
        "saturacao_oferecida_rps": round(knee, 1),
        "erro5pct_em_rps": round(over.offered_rps.min(), 1) if not over.empty else None,
        "descarte10pct_em_rps": round(drops.offered_rps.min(), 1) if not drops.empty else None,
    }


def figure(curves, sm, long):
    # Dois painéis empilhados sobre o mesmo eixo x. Throughput e taxa de erro têm
    # unidades e escalas distintas: num eixo y secundário, a escolha das escalas
    # sugeriria qualquer relação desejada entre as duas curvas.
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8, 7), sharex=True,
                                   gridspec_kw={"height_ratios": [2, 1]})
    # Referência y = x: no eixo x logarítmico ela é uma curva, e traçá-la com dois
    # pontos a deixaria quase horizontal, parecendo um teto. O eixo y fica preso à
    # faixa dos dados, senão a referência estica a escala e achata as curvas reais.
    lo, hi = long.offered_rps.min(), long.offered_rps.max()
    ymax = long.achieved_rps.max() * 1.15
    xs = np.logspace(np.log10(lo), np.log10(hi), 200)
    ax1.plot(xs, xs, color="0.75", lw=1, ls=(0, (2, 3)), zorder=1)
    ax1.set_ylim(0, ymax)
    ax1.set_xlim(lo, hi)
    xr = float(np.interp(0.72 * ymax, xs, xs))
    ax1.annotate("resposta ideal", xy=(xr, 0.72 * ymax), xytext=(6, -2),
                 textcoords="offset points", ha="left", va="top", color="0.45", fontsize=9)

    for t, g in curves.items():
        kw = dict(color=COLOR[t], marker=MARK[t], ls=DASH[t], lw=2, ms=6, zorder=3)
        ax1.plot(g.offered_rps, g.achieved_rps, label=LABEL[t], **kw)
        ax2.plot(g.offered_rps, g.error_pct, **kw)
        knee = sm.loc[t, "saturacao_oferecida_rps"] if t in sm.index else None
        if knee is not None and not pd.isna(knee):
            y = g.loc[(g.offered_rps - knee).abs().idxmin(), "achieved_rps"]
            ax1.plot([knee], [y], marker="*", ms=16, color=COLOR[t],
                     mec="white", mew=1.2, ls="none", zorder=4)

    ax1.set_ylabel("Throughput atingido (req/s)")
    ax1.set_xscale("log")
    ax1.grid(True, alpha=0.25, lw=0.6)
    ax1.legend(frameon=False, loc="upper left")
    ax1.set_title("Saturação por arquitetura (estrela: ponto de saturação)")

    ax2.axhline(ERR_LEVEL, color="0.75", lw=1, ls=(0, (2, 3)), zorder=1)
    ax2.set_ylabel("Erro (%)")
    ax2.set_xlabel("Taxa de chegada oferecida (req/s, escala log)")
    ax2.grid(True, alpha=0.25, lw=0.6)

    fig.tight_layout()
    fig.savefig(os.path.join(FIG, "calibration.png"), dpi=150)
    plt.close(fig)


def main():
    curves, summary, rpi = {}, [], {}
    for target in ORDER:
        paths = sorted(glob.glob(os.path.join(RESULTS, target, "*", "calibration-rep01-raw.json*")))
        if not paths:
            continue
        if len(paths) > 1:
            print(f"aviso: {target} tem {len(paths)} calibrações; usando a mais recente")
        loaded = load_run(paths[-1])
        if loaded is None:
            continue
        df, r = loaded
        rpi[target] = r
        g = to_levels(df)
        if g.empty:
            continue
        curves[target] = g
        s = saturation(g)
        s.update({"alvo": target, "req_por_iteracao": round(r, 2)})
        summary.append(s)

    if not curves:
        sys.exit(f"Nenhum calibration-rep01-raw.json em {RESULTS}/<alvo>/<ts>/")

    long = pd.concat([g.assign(alvo=t) for t, g in curves.items()], ignore_index=True)
    long.to_csv(os.path.join(TAB, "calibration_curve.csv"), index=False)
    sm = pd.DataFrame(summary).set_index("alvo").reindex([t for t in ORDER if t in curves])
    sm.to_csv(os.path.join(TAB, "calibration_summary.csv"))

    figure(curves, sm, long)

    print("\n=== Calibração: teto por arquitetura ===")
    print(sm.to_string())
    if sm["teto_rps"].notna().any():
        teto = sm["teto_rps"].max()
        r = float(np.mean(list(rpi.values())))
        print(f"\nMaior teto observado: {teto:.0f} req/s ({r:.2f} req por iteração)")
        print(f"PEAK_RATE sugerido para o cenário de pico: {1.5 * teto / r:.0f} iter/s")
        print("(1,5x o maior teto, para que os três braços ultrapassem a saturação)")
    print(f"\nFigura em {FIG}/calibration.png; tabelas em {TAB}/")


if __name__ == "__main__":
    main()
