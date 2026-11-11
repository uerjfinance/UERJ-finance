"""Atualização diária das cotações do site UERJ Finance.

Roda em dias úteis às 12h (preço do pregão em andamento) e às 20h (fechamento) de Brasília, pelo
GitHub Actions (.github/workflows/atualizar-cotacoes.yml). Lê a composição do Ibovespa na B3, busca os preços de
fechamento no Yahoo Finance e grava site/dados/cotacoes.json, que o site lê ao abrir.

Uso:
  python agente/atualizar_cotacoes.py --fonte yahoo --saida ../site/dados/cotacoes.json
  python agente/atualizar_cotacoes.py --fonte ficticia --forcar   # teste sem internet

Regras de segurança:
  - Sem pregão hoje (feriado da B3): não grava nada e sai com sucesso.
  - Ação sem preço ou com variação diária acima de 35%: fica de fora e entra em "alertas";
    o site mantém o último valor válido.
  - Mais da metade das ações sem dados: falha (código 1), não grava, e o GitHub avisa por e-mail.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from datetime import datetime
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from composicao import montar_universo  # noqa: E402
from fontes import BRT, criar_fonte  # noqa: E402

RAIZ = Path(__file__).resolve().parents[1]
VARIACAO_MAXIMA = 35.0  # % em um dia; acima disso o dado é tratado como erro
SETORES_EN = {"Financial Services": "Serviços financeiros", "Energy": "Petróleo e gás", "Utilities": "Energia e saneamento",
              "Basic Materials": "Materiais básicos", "Industrials": "Indústria", "Consumer Cyclical": "Consumo cíclico",
              "Consumer Defensive": "Consumo não cíclico", "Healthcare": "Saúde", "Real Estate": "Imobiliário",
              "Communication Services": "Telecomunicações", "Technology": "Tecnologia"}


def _num(v, casas=2):
    if v is None:
        return None
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return round(v, casas) if math.isfinite(v) else None


def _var(serie: pd.Series, n: int):
    """Variação % entre o último preço e o de n pregões atrás."""
    s = serie.dropna()
    if len(s) <= n:
        return None
    return _num((s.iloc[-1] / s.iloc[-1 - n] - 1) * 100, 1)


def resumo(serie: pd.Series) -> dict:
    s = serie.dropna()
    ult = s.iloc[-252:]
    return {"p": _num(s.iloc[-1]), "d": _var(s, 1), "m": _var(s, 21), "y": _var(s, 252),
            "lo": _num(ult.min()), "hi": _num(ult.max())}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fonte", default="yahoo", choices=["yahoo", "ficticia"])
    ap.add_argument("--universo", default=str(RAIZ / "config" / "universo.json"))
    ap.add_argument("--saida", default=str(RAIZ.parent / "site" / "dados" / "cotacoes.json"))
    ap.add_argument("--desde", default="2026-08-01", help="início do histórico diário usado nos gráficos")
    ap.add_argument("--fundamentos", action="store_true", help="também busca P/L, P/VP e ROE (lento e instável no Yahoo)")
    ap.add_argument("--forcar", action="store_true", help="grava mesmo sem pregão hoje")
    a = ap.parse_args()

    config = json.loads(Path(a.universo).read_text(encoding="utf-8"))
    universo, alertas_comp = montar_universo(config)
    print(f"Universo: {len(universo['acoes'])} ativos (composição do Ibovespa via {universo['composicao']}).")
    fonte = criar_fonte(a.fonte, a.desde, a.fundamentos)
    if a.fonte == "yahoo":
        # Rodada das 12h: preço do pregão em andamento. Rodada das 20h: fechamento oficial.
        fonte.intradiario = datetime.now(BRT).hour < 18
    dados = fonte.carregar(universo)
    precos = dados.precos.sort_index().ffill()
    alertas = alertas_comp + list(dados.alertas)

    hoje = datetime.now(BRT).date()
    bench = universo["benchmark"]["ticker"]
    ultimo_pregao = precos[bench].dropna().index[-1].date() if bench in precos else None
    if ultimo_pregao != hoje and not a.forcar:
        print(f"Sem pregão hoje ({hoje:%d/%m/%Y}); último pregão: {ultimo_pregao}. Nada a gravar.")
        return 0

    acoes, faltando = [], []
    for at in universo["acoes"]:
        t = at["ticker"]
        if t not in precos or precos[t].dropna().empty:
            faltando.append(t)
            continue
        r = resumo(precos[t])
        if r["d"] is not None and abs(r["d"]) > VARIACAO_MAXIMA:
            alertas.append(f"{t}: variação de {r['d']}% no dia descartada para revisão manual.")
            faltando.append(t)
            continue
        f = dados.fundamentos.get(t) or {} if a.fundamentos else {}
        r.update({k: _num(f.get(k), 0 if k == "mc" else 1) for k in ("pl", "pvp", "roe", "dy", "mc") if f.get(k) is not None})
        setor = at.get("setor") or SETORES_EN.get(f.get("setor_en") or "", "Outros")
        acoes.append({"t": t, "n": at.get("nome") or f.get("nome") or t, "s": setor, "ib": at.get("ib", True),
                      "peso": _num(at.get("peso"), 3), **r})

    if len(faltando) > len(universo["acoes"]) / 2:
        print(f"Falha: {len(faltando)} de {len(universo['acoes'])} ações sem dados válidos. Arquivo não atualizado.", file=sys.stderr)
        return 1
    if faltando:
        alertas.append("Sem dados válidos hoje: " + ", ".join(faltando) + ". O site mantém o último valor.")

    hist = precos[precos.index >= pd.Timestamp(a.desde)].bfill()
    tks = [x["t"] for x in acoes] + ([bench] if bench in hist else [])
    saida = {
        "fonte": "Yahoo Finance" if a.fonte == "yahoo" else "Simulação (fonte fictícia)",
        "composicao": universo["composicao"],
        "data_ref": f"{ultimo_pregao:%d/%m/%Y}" if ultimo_pregao else f"{hoje:%d/%m/%Y}",
        "gerado_em": datetime.now(BRT).isoformat(timespec="minutes"),
        "ibov": resumo(precos[bench]) if bench in precos else None,
        "acoes": acoes,
        "alertas": alertas,
        "historico": {
            "datas": [d.strftime("%Y-%m-%d") for d in hist.index],
            "precos": {t: [_num(v, 0 if t == bench else 2) for v in hist[t]] for t in tks},
        },
    }
    destino = Path(a.saida)
    destino.parent.mkdir(parents=True, exist_ok=True)
    destino.write_text(json.dumps(saida, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"{len(acoes)} ações gravadas em {destino} (pregão de {saida['data_ref']}).")
    for x in alertas:
        print("ALERTA:", x)
    return 0


if __name__ == "__main__":
    sys.exit(main())
