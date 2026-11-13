-- =====================================================================
-- Compra manual de ações para o Fundo da Liga (presidente e quem tiver "editarFundo")
-- O servidor confere a permissão e se há caixa suficiente antes de comprar.
-- Caixa = R$ 1.000.000 - custo das posições + lucro/prejuízo realizado nas vendas.
-- =====================================================================
create or replace function public.caixa_do_fundo() returns numeric
language sql stable security definer set search_path = public as $$
  select 1000000
       - coalesce((select sum(p.quantidade * p.preco_entrada) from posicoes p join carteiras c on c.id = p.carteira_id where c.is_liga), 0)
       + coalesce((select sum(m.quantidade * (m.preco - coalesce(m.preco_entrada, m.preco))) from movimentacoes m join carteiras c on c.id = m.carteira_id where c.is_liga and m.tipo = 'venda'), 0);
$$;

create or replace function public.adicionar_ao_fundo(p_ticker text, p_preco numeric, p_valor numeric, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_cart uuid; v_tk text := upper(trim(p_ticker)); v_qtd integer; v_custo numeric; v_caixa numeric; v_nome text;
  v_atual integer; v_pm numeric;
begin
  if not tem_permissao('editarFundo') then raise exception 'Sem permissão para alterar o Fundo da Liga'; end if;
  if v_tk !~ '^[A-Z]{4}[0-9]{1,2}$' then raise exception 'Ticker inválido: %', v_tk; end if;
  if char_length(coalesce(trim(p_motivo), '')) < 5 then raise exception 'Informe o motivo da compra'; end if;
  if p_preco is null or p_preco <= 0 or p_preco > 100000 then raise exception 'Preço inválido'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Valor inválido'; end if;
  v_qtd := floor(p_valor / p_preco);
  if v_qtd < 1 then raise exception 'O valor não compra nem uma ação de %', v_tk; end if;
  v_custo := round(v_qtd * p_preco, 2);
  select id into v_cart from carteiras where is_liga for update;   -- trava: duas compras simultâneas não gastam o mesmo caixa
  if v_cart is null then raise exception 'Fundo da Liga não encontrado'; end if;
  v_caixa := caixa_do_fundo();
  if v_custo > v_caixa + 0.01 then raise exception 'Caixa insuficiente: a compra custa R$ % e o fundo tem R$ % em caixa', v_custo, round(v_caixa, 2); end if;
  select sum(quantidade), sum(quantidade * preco_entrada) into v_atual, v_pm from posicoes where carteira_id = v_cart and ticker = v_tk;
  if v_atual is null then
    insert into posicoes (carteira_id, ticker, quantidade, preco_entrada, data_entrada)
    values (v_cart, v_tk, v_qtd, round(p_preco, 2), (now() at time zone 'America/Sao_Paulo')::date);
  else
    -- reforço de posição: soma a quantidade e recalcula o preço médio
    delete from posicoes where carteira_id = v_cart and ticker = v_tk and id <> (select min(id::text)::uuid from posicoes where carteira_id = v_cart and ticker = v_tk);
    update posicoes set quantidade = v_atual + v_qtd, preco_entrada = round((v_pm + v_qtd * p_preco) / (v_atual + v_qtd), 2)
     where carteira_id = v_cart and ticker = v_tk;
  end if;
  select nome into v_nome from perfis where id = auth.uid();
  insert into movimentacoes (carteira_id, ticker, tipo, quantidade, preco, motivo, autor_id, autor_nome)
  values (v_cart, v_tk, 'compra', v_qtd, round(p_preco, 2), left(trim(p_motivo), 500), auth.uid(), v_nome);
  insert into auditoria (autor_id, acao)
  values (auth.uid(), 'comprou ' || v_qtd || ' ações de ' || v_tk || ' para o Fundo da Liga a R$ ' || round(p_preco, 2));
end $$;
revoke execute on function public.adicionar_ao_fundo(text, numeric, numeric, text) from anon, public;
grant execute on function public.adicionar_ao_fundo(text, numeric, numeric, text) to authenticated;
revoke execute on function public.caixa_do_fundo() from anon, public;
grant execute on function public.caixa_do_fundo() to authenticated;
