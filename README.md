# UERJ Finance

Site da Liga de Mercado Financeiro da UERJ.

- `index.html`: o site (página única).
- `dados/cotacoes.json`: cotações gravadas pelo agente (não editar à mão).
- `agente/`: script que busca as cotações no Yahoo Finance.
- `.github/workflows/atualizar-cotacoes.yml`: roda o agente nos dias úteis às 12:00 e às 20:00 (Brasília).
- `config/`: universo de ações e carteiras de referência.
- `supabase/esquema.sql`: banco de dados, contas e regras de acesso (Supabase).
