"""Fontes de dados do agente.

Cada fonte devolve um objeto `Dados` com:
  precos      DataFrame (índice = datas de pregão, colunas = tickers + benchmark), em R$.
              A última linha é o preço mais recente (pode ser intradiário).
  proventos   DataFrame do mesmo formato: provento por ação na data ex (0 nos demais dias).
  fundamentos dict ticker -> {pl, pvp, roe, data_ref}

Para trocar de fonte basta mudar FONTE=ficticia|yahoo (variável de ambiente ou --fonte).
"""
from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone

import numpy as np
import pandas as pd

BRT = timezone(timedelta(hours=-3))


@dataclass
class Dados:
    precos: pd.DataFrame
    proventos: pd.DataFrame
    fundamentos: dict = field(default_factory=dict)
    alertas: list = field(default_factory=list)


def _semente(texto: str) -> int:
    return int(hashlib.sha256(texto.encode()).hexdigest()[:8], 16)


class FonteFicticia:
    """Gera preços simulados, determinísticos e que 'andam' a cada execução.

    - Histórico diário: passeio aleatório lognormal com semente fixa por ticker,
      calibrado para terminar perto do `preco_base` do universo.
    - Pregão de hoje: o último preço muda a cada janela de 30 minutos,
      imitando a atualização contínua que o Yahoo terá.
    - Proventos: pagamentos trimestrais coerentes com o DY do universo.
    """

    nome = "ficticia"

    def __init__(self, agora: datetime | None = None, dias_historico: int = 420):
        self.agora = agora or datetime.now(BRT)
        self.dias_historico = dias_historico

    def carregar(self, universo: dict) -> Dados:
        hoje = self.agora.date()
        datas = pd.bdate_range(end=hoje, periods=self.dias_historico)
        ativos = [(a["ticker"], a["preco_base"], a.get("dy") or 0.0, 0.019) for a in universo["acoes"]]
        b = universo["benchmark"]
        ativos.append((b["ticker"], b["preco_base"], 0.0, 0.011))

        precos, provs = {}, {}
        janela = self.agora.hour * 2 + self.agora.minute // 30
        for tk, base, dy, vol in ativos:
            rng = np.random.default_rng(_semente(tk))
            ret = rng.normal(0.0003, vol, len(datas))
            # componente intradiário de hoje: muda a cada 30 minutos
            rng_hoje = np.random.default_rng(_semente(f"{tk}|{hoje}|{janela}"))
            ret[-1] = rng_hoje.normal(0.0, vol * 0.6)
            serie = np.exp(np.cumsum(ret))
            serie = serie / serie[-1] * base
            precos[tk] = np.round(serie, 2)
            p = np.zeros(len(datas))
            if dy > 0:
                for i, d in enumerate(datas):
                    if d.month in (3, 6, 9, 12) and d.day >= 15 and (i == 0 or datas[i - 1].day < 15 or datas[i - 1].month != d.month):
                        p[i] = round(serie[i] * dy / 100 / 4, 4)
            provs[tk] = p
        df_p = pd.DataFrame(precos, index=datas)
        df_d = pd.DataFrame(provs, index=datas)
        fund = {a["ticker"]: {"pl": a.get("pl"), "pvp": a.get("pvp"), "roe": a.get("roe"), "data_ref": "fictício"}
                for a in universo["acoes"]}
        return Dados(df_p, df_d, fund)


class FonteYahoo:
    """Dados reais do Yahoo Finance via biblioteca yfinance (tickers com sufixo .SA)."""

    nome = "yahoo"

    def __init__(self, inicio: str, fundamentos: bool = False):
        self.inicio = (pd.Timestamp(inicio) - pd.Timedelta(days=400)).date()
        self.fundamentos = fundamentos
        self.intradiario = True  # False na carga de fechamento (20h): usa só o preço oficial

    @staticmethod
    def _yf(tk: str) -> str:
        return tk if tk.startswith("^") else f"{tk}.SA"

    def carregar(self, universo: dict) -> Dados:
        import yfinance as yf  # importado só quando a fonte real é usada

        tks = [a["ticker"] for a in universo["acoes"]] + [universo["benchmark"]["ticker"]]
        mapa = {self._yf(t): t for t in tks}
        alertas = []

        hist = yf.download(list(mapa), start=str(self.inicio), auto_adjust=False, actions=True,
                           group_by="column", progress=False, threads=True)
        precos = hist["Close"].rename(columns=mapa)
        proventos = hist["Dividends"].rename(columns=mapa).fillna(0.0) if "Dividends" in hist else precos * 0

        # preço intradiário mais recente (atraso típico de ~15 min)
        try:
            if not self.intradiario:
                raise StopIteration
            intra = yf.download(list(mapa), period="1d", interval="5m", progress=False, threads=True)["Close"]
            ult = intra.rename(columns=mapa).ffill().iloc[-1]
            hoje = pd.Timestamp(datetime.now(BRT).date())
            if hoje not in precos.index:
                precos.loc[hoje] = np.nan
                proventos.loc[hoje] = 0.0
            for t, v in ult.items():
                if pd.notna(v):
                    precos.loc[hoje, t] = float(v)
        except StopIteration:
            pass
        except Exception as e:  # noqa: BLE001
            alertas.append(f"Preço intradiário indisponível: {e}")

        precos.index = pd.to_datetime(precos.index).tz_localize(None).normalize()
        proventos.index = precos.index
        precos = precos.sort_index().ffill()
        for t in tks:
            if t not in precos or precos[t].isna().all():
                alertas.append(f"Sem dados do Yahoo para {t}")

        fund = {}
        if self.fundamentos:  # lento e pouco confiável para ações brasileiras: só na carga de fechamento
            for t in [a["ticker"] for a in universo["acoes"]]:
                try:
                    info = yf.Ticker(self._yf(t)).info
                    roe, dy, mc = info.get("returnOnEquity"), info.get("trailingAnnualDividendYield"), info.get("marketCap")
                    fund[t] = {"pl": info.get("trailingPE"), "pvp": info.get("priceToBook"),
                               "roe": round(roe * 100, 1) if roe is not None else None,
                               "dy": round(dy * 100, 1) if dy is not None else None,
                               "mc": round(mc / 1e9) if mc else None,  # R$ bilhões
                               "setor_en": info.get("sector"), "nome": info.get("shortName"),
                               "data_ref": date.today().isoformat()}
                except Exception as e:  # noqa: BLE001
                    alertas.append(f"Fundamentos indisponíveis para {t}: {e}")
        return Dados(precos, proventos.reindex(precos.index).fillna(0.0), fund, alertas)


def criar_fonte(nome: str, inicio: str, fundamentos: bool = False):
    if nome == "yahoo":
        return FonteYahoo(inicio, fundamentos)
    if nome == "ficticia":
        return FonteFicticia()
    raise ValueError(f"Fonte desconhecida: {nome} (use 'ficticia' ou 'yahoo')")
