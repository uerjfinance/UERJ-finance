-- =====================================================================
-- Retirada manual de ações do Fundo da Liga (presidente e quem tiver "editarFundo")
-- Aplicada automaticamente pelo workflow "Aplicar migrações do banco" ao entrar na main.
-- =====================================================================

-- 1. Histórico de movimentações do fundo (leitura pública; escrita só pela função abaixo)
create table if not exists public.movimentacoes (
  id            bigint generated always as identity primary key,
  carteira_id   uuid not null references public.carteiras(id) on delete cascade,
  ticker        text not null,
  tipo          text not null check (tipo in ('venda','compra')),
  quantidade    integer not null check (quantidade > 0),
  preco         numeric(12,2) not null check (preco > 0),
  preco_entrada numeric(12,2),
  motivo        text not null default '',
  autor_id      uuid references public.perfis(id),
  autor_nome    text,
  quando        timestamptz not null default now()
);
alter table public.movimentacoes enable row level security;
drop policy if exists movimentacoes_ler on public.movimentacoes;
create policy movimentacoes_ler on public.movimentacoes for select using (true);
revoke insert, update, delete on public.movimentacoes from anon, authenticated;

-- 2. Fundo da Liga no banco, com a carteira de constituição (fictícia nesta fase)
insert into public.carteiras (is_liga, nome, motivacao)
select true, 'Fundo da Liga', ''
where not exists (select 1 from public.carteiras where is_liga);

insert into public.posicoes (carteira_id, ticker, quantidade, preco_entrada, data_entrada)
select c.id, v.ticker, v.qtd, v.preco, v.data::date
from public.carteiras c,
  (values
    ('ITUB4', 3283, 33.50, '2026-08-01'),
    ('BPAC11', 1842, 38.00, '2026-08-01'),
    ('WEGE3', 2469, 40.50, '2026-08-01'),
    ('SBSP3', 980, 102.00, '2026-08-01'),
    ('EQTL3', 2461, 32.50, '2026-08-01'),
    ('TAEE11', 2000, 35.00, '2026-08-01'),
    ('PETR4', 2571, 35.00, '2026-08-01'),
    ('SUZB3', 1250, 56.00, '2026-08-01'),
    ('MELI34', 978, 92.00, '2026-08-01'),
    ('RADL3', 2500, 24.00, '2026-08-01'),
    ('ABEV3', 4545, 13.20, '2026-08-01'),
    ('RENT3', 1363, 44.00, '2026-08-01')
  ) as v(ticker, qtd, preco, data)
where c.is_liga
  and not exists (select 1 from public.posicoes p where p.carteira_id = c.id)
  and not exists (select 1 from public.movimentacoes m where m.carteira_id = c.id);

-- 3. Retirar uma ação do fundo: vende a posição inteira ao preço informado (fechamento mais recente)
create or replace function public.retirar_do_fundo(p_ticker text, p_preco numeric, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_cart uuid; v_qtd integer; v_pm numeric; v_nome text; v_tk text := upper(trim(p_ticker));
begin
  if not tem_permissao('editarFundo') then raise exception 'Sem permissão para alterar o Fundo da Liga'; end if;
  if char_length(coalesce(trim(p_motivo), '')) < 5 then raise exception 'Informe o motivo da retirada'; end if;
  select id into v_cart from carteiras where is_liga;
  select sum(quantidade), sum(quantidade * preco_entrada) / sum(quantidade) into v_qtd, v_pm
    from posicoes where carteira_id = v_cart and ticker = v_tk;
  if v_qtd is null then raise exception 'A ação % não está no Fundo da Liga', v_tk; end if;
  -- trava contra preço digitado errado: aceita de 20% a 500% do preço médio de compra
  if p_preco is null or p_preco < v_pm * 0.2 or p_preco > v_pm * 5 then raise exception 'Preço de venda fora do esperado para %', v_tk; end if;
  select nome into v_nome from perfis where id = auth.uid();
  delete from posicoes where carteira_id = v_cart and ticker = v_tk;
  insert into movimentacoes (carteira_id, ticker, tipo, quantidade, preco, preco_entrada, motivo, autor_id, autor_nome)
  values (v_cart, v_tk, 'venda', v_qtd, round(p_preco, 2), round(v_pm, 2), left(trim(p_motivo), 500), auth.uid(), v_nome);
  insert into auditoria (autor_id, acao)
  values (auth.uid(), 'retirou ' || v_tk || ' do Fundo da Liga (' || v_qtd || ' ações a R$ ' || round(p_preco, 2) || ')');
end $$;
revoke execute on function public.retirar_do_fundo(text, numeric, text) from anon, public;
grant execute on function public.retirar_do_fundo(text, numeric, text) to authenticated;
