"""Composição oficial do Ibovespa, lida da B3 a cada execução do agente.

A B3 revisa a carteira teórica três vezes por ano (janeiro, maio e setembro). Ler a composição
na hora evita manter uma lista manual: ações que entram no índice aparecem no site no mesmo dia,
e as que saem deixam de ser atualizadas. Se a B3 não responder, o agente usa a lista reserva
de config/universo.json e registra um alerta.
"""
from __future__ import annotations

import base64
import json
import urllib.request

URL = "https://sistemaswebb3-listados.b3.com.br/indexProxy/indexCall/GetPortfolioDay/"


def _num(txt) -> float | None:
    try:
        return float(str(txt).replace(".", "").replace(",", ".")) if "," in str(txt) else float(txt)
    except (TypeError, ValueError):
        return None


def composicao_b3(indice: str = "IBOV", timeout: int = 30) -> list[dict]:
    """Devolve [{ticker, nome_b3, peso}] da carteira do dia. Levanta exceção se a resposta for inválida."""
    q = base64.b64encode(json.dumps({"language": "pt-br", "pageNumber": 1, "pageSize": 150,
                                     "index": indice, "segment": "1"}).encode()).decode()
    req = urllib.request.Request(URL + q, headers={"User-Agent": "Mozilla/5.0 (uerj-finance-agente)"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        dados = json.load(r)
    itens = [{"ticker": str(x.get("cod", "")).strip().upper(), "nome_b3": str(x.get("asset", "")).strip().title(),
              "peso": _num(x.get("part"))} for x in dados.get("results", [])]
    itens = [x for x in itens if x["ticker"]]
    if not 40 <= len(itens) <= 150:
        raise ValueError(f"composição com {len(itens)} ativos, fora do esperado")
    return itens


def montar_universo(config: dict) -> tuple[dict, list[str]]:
    """Universo efetivo = composição do Ibovespa (B3 ou reserva) + extras (BDRs das carteiras)."""
    alertas = []
    meta = {a["ticker"]: a for a in config["acoes"] + config.get("extras", [])}
    try:
        comp = composicao_b3()
        fonte_comp = "B3"
    except Exception as e:  # noqa: BLE001
        alertas.append(f"Composição da B3 indisponível ({e}); usada a lista reserva de config/universo.json.")
        comp = [{"ticker": a["ticker"], "nome_b3": a["nome"], "peso": None} for a in config["acoes"]]
        fonte_comp = "lista reserva"
    acoes = []
    for c in comp:
        m = meta.get(c["ticker"], {})
        acoes.append({"ticker": c["ticker"], "nome": m.get("nome") or c["nome_b3"], "setor": m.get("setor"),
                      "preco_base": m.get("preco_base", 20.0), "dy": m.get("dy"), "pl": m.get("pl"),
                      "pvp": m.get("pvp"), "roe": m.get("roe"), "peso": c["peso"], "ib": True})
    no_indice = {a["ticker"] for a in acoes}
    for x in config.get("extras", []):
        if x["ticker"] not in no_indice:
            acoes.append({**x, "peso": None, "ib": False})
    return {"benchmark": config["benchmark"], "acoes": acoes, "composicao": fonte_comp}, alertas
