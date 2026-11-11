-- =====================================================================
-- UERJ Finance · Contas, aprovação, permissões e carteiras (Supabase)
-- Rodar uma vez no SQL Editor do projeto Supabase.
-- Princípio: toda regra de acesso vive AQUI, no servidor. O site apenas
-- esconde botões; quem impede o acesso indevido é o Row Level Security.
-- =====================================================================

-- ---------- 1. Perfis (1 linha por usuário do Supabase Auth) ----------
create table public.perfis (
  id            uuid primary key references auth.users(id) on delete cascade,
  nome          text not null check (char_length(nome) between 3 and 60),
  email         text not null unique,
  matricula     text not null,
  curso         text not null,
  papel         text not null default 'membro'   check (papel in ('presidente','membro')),
  status        text not null default 'pendente' check (status in ('pendente','ativo','recusado','suspenso')),
  consentimento timestamptz not null default now(),   -- aceite LGPD no cadastro
  criado_em     timestamptz not null default now(),
  decidido_por  uuid references public.perfis(id),
  decidido_em   timestamptz
);
-- Exatamente um presidente por vez (no máximo um; a transferência é atômica).
create unique index um_presidente on public.perfis ((true)) where papel = 'presidente';

-- ---------- 2. Permissões granulares, concedidas só pelo presidente ----------
create table public.permissoes (
  usuario_id    uuid not null references public.perfis(id) on delete cascade,
  permissao     text not null check (permissao in ('aprovar','publicar','editarFundo','decidir','moderar')),
  concedido_por uuid not null references public.perfis(id),
  concedido_em  timestamptz not null default now(),
  primary key (usuario_id, permissao)
);

-- ---------- 3. Carteiras: no máximo 1 por membro ----------
create table public.carteiras (
  id         uuid primary key default gen_random_uuid(),
  dono_id    uuid references public.perfis(id) on delete restrict,
  is_liga    boolean not null default false,
  nome       text not null,
  motivacao  text default '',
  criada_em  timestamptz not null default now(),
  constraint dono_ou_liga check ((is_liga and dono_id is null) or (not is_liga and dono_id is not null))
);
create unique index uma_carteira_por_membro on public.carteiras (dono_id) where dono_id is not null;
create unique index um_fundo_da_liga       on public.carteiras ((true)) where is_liga;

create table public.posicoes (
  id            uuid primary key default gen_random_uuid(),
  carteira_id   uuid not null references public.carteiras(id) on delete cascade,
  ticker        text not null,
  quantidade    integer not null check (quantidade > 0),
  preco_entrada numeric(12,2) not null,   -- preenchido pelo sistema (cotação do dia), não pelo membro
  data_entrada  date not null default current_date,
  tese          text default ''
);

-- ---------- 4. Registro de auditoria ----------
create table public.auditoria (
  id        bigint generated always as identity primary key,
  quando    timestamptz not null default now(),
  autor_id  uuid references public.perfis(id),
  acao      text not null
);

-- ---------- 5. Funções auxiliares (usadas nas regras) ----------
create or replace function public.eh_ativo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfis where id = auth.uid() and status = 'ativo');
$$;

create or replace function public.eh_presidente() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from perfis where id = auth.uid() and status = 'ativo' and papel = 'presidente');
$$;

create or replace function public.tem_permissao(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_presidente()
      or (public.eh_ativo() and exists (select 1 from permissoes where usuario_id = auth.uid() and permissao = p));
$$;

-- ---------- 6. Cadastro: todo novo usuário nasce "pendente" ----------
create or replace function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfis (id, nome, email, matricula, curso)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nome', ''),
          new.email,
          coalesce(new.raw_user_meta_data->>'matricula', ''),
          coalesce(new.raw_user_meta_data->>'curso', ''));
  insert into auditoria (autor_id, acao) values (new.id, 'pediu cadastro.');
  return new;
end $$;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.novo_usuario();

-- ---------- 7. Ações administrativas (únicas portas de escrita) ----------
create or replace function public.decidir_cadastro(alvo uuid, aprovar boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not tem_permissao('aprovar') then raise exception 'Sem permissão para aprovar cadastros'; end if;
  update perfis set status = case when aprovar then 'ativo' else 'recusado' end,
                    decidido_por = auth.uid(), decidido_em = now()
   where id = alvo and status = 'pendente';
  insert into auditoria (autor_id, acao)
  values (auth.uid(), (case when aprovar then 'aprovou' else 'recusou' end) || ' o cadastro de ' || (select nome from perfis where id = alvo));
end $$;

create or replace function public.definir_permissao(alvo uuid, p text, conceder boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not eh_presidente() then raise exception 'Apenas o presidente concede permissões'; end if;
  if conceder then
    insert into permissoes (usuario_id, permissao, concedido_por) values (alvo, p, auth.uid()) on conflict do nothing;
  else
    delete from permissoes where usuario_id = alvo and permissao = p;
  end if;
  insert into auditoria (autor_id, acao)
  values (auth.uid(), (case when conceder then 'concedeu ' else 'retirou ' end) || p || ' de ' || (select nome from perfis where id = alvo));
end $$;

create or replace function public.definir_status(alvo uuid, novo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not eh_presidente() then raise exception 'Apenas o presidente suspende ou reativa'; end if;
  if novo not in ('ativo','suspenso') then raise exception 'Status inválido'; end if;
  update perfis set status = novo where id = alvo and papel <> 'presidente';
  insert into auditoria (autor_id, acao) values (auth.uid(), 'alterou status de ' || (select nome from perfis where id = alvo) || ' para ' || novo);
end $$;

create or replace function public.transferir_presidencia(novo uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not eh_presidente() then raise exception 'Apenas o presidente transfere a presidência'; end if;
  if not exists (select 1 from perfis where id = novo and status = 'ativo') then raise exception 'Destinatário inválido'; end if;
  update perfis set papel = 'membro' where id = auth.uid();
  delete from permissoes where usuario_id = auth.uid();
  update perfis set papel = 'presidente' where id = novo;
  insert into auditoria (autor_id, acao) values (auth.uid(), 'transferiu a presidência para ' || (select nome from perfis where id = novo));
end $$;

-- ---------- 8. Row Level Security ----------
alter table public.perfis     enable row level security;
alter table public.permissoes enable row level security;
alter table public.carteiras  enable row level security;
alter table public.posicoes   enable row level security;
alter table public.auditoria  enable row level security;

-- Perfis: cada um vê o próprio; quem aprova cadastros vê todos (matrícula e e-mail não são públicos).
create policy perfis_ler on public.perfis for select
  using (id = auth.uid() or tem_permissao('aprovar'));
-- Ninguém altera papel/status diretamente: só pelas funções acima.
revoke update, insert, delete on public.perfis from anon, authenticated;
grant update (nome, curso) on public.perfis to authenticated;
create policy perfis_editar_proprio on public.perfis for update
  using (id = auth.uid()) with check (id = auth.uid());

-- Permissões: o próprio usuário vê as suas; o presidente vê todas. Escrita só por definir_permissao().
create policy permissoes_ler on public.permissoes for select
  using (usuario_id = auth.uid() or eh_presidente());
revoke insert, update, delete on public.permissoes from anon, authenticated;

-- Carteiras: leitura pública (o site é aberto); criação só da própria, por membro ativo.
create policy carteiras_ler on public.carteiras for select using (true);
create policy carteiras_criar on public.carteiras for insert
  with check (not is_liga and dono_id = auth.uid() and eh_ativo());   -- o índice único barra a 2ª carteira
create policy carteiras_editar on public.carteiras for update
  using ((is_liga and tem_permissao('editarFundo'))
      or (not is_liga and ((dono_id = auth.uid() and eh_ativo()) or tem_permissao('moderar'))));
create policy carteiras_excluir on public.carteiras for delete
  using (not is_liga and tem_permissao('moderar'));                    -- o dono NÃO exclui a própria

-- Posições: mesma regra de edição da carteira a que pertencem.
create policy posicoes_ler on public.posicoes for select using (true);
create policy posicoes_escrever on public.posicoes for all
  using (exists (select 1 from carteiras c where c.id = carteira_id and
         ((c.is_liga and tem_permissao('editarFundo'))
          or (not c.is_liga and ((c.dono_id = auth.uid() and eh_ativo()) or tem_permissao('moderar'))))))
  with check (exists (select 1 from carteiras c where c.id = carteira_id and
         ((c.is_liga and tem_permissao('editarFundo'))
          or (not c.is_liga and ((c.dono_id = auth.uid() and eh_ativo()) or tem_permissao('moderar'))))));

-- Auditoria: só o presidente lê; ninguém escreve diretamente.
create policy auditoria_ler on public.auditoria for select using (eh_presidente());
revoke insert, update, delete on public.auditoria from anon, authenticated;

-- ---------- 9. Primeiro presidente (rodar UMA vez, depois de o Gabriel se cadastrar pelo site) ----------
-- update public.perfis set papel = 'presidente', status = 'ativo' where email = 'EMAIL_DO_GABRIEL';
-- insert into public.carteiras (is_liga, nome) values (true, 'Fundo da Liga');
