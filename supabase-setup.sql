-- ════════════════════════════════════════════════════════════════
-- 3DSTORE — SUPABASE SETUP COMPLETO
-- Executa no SQL Editor do teu projeto Supabase
-- ════════════════════════════════════════════════════════════════

-- ── 1. TABELA: products ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS products (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT        NOT NULL,
  description TEXT        NOT NULL DEFAULT '',
  price_ton   NUMERIC     NOT NULL CHECK (price_ton > 0),
  tag         TEXT,
  sort_order  INTEGER     NOT NULL DEFAULT 1,
  active      BOOLEAN     NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- RLS: qualquer pessoa pode LER produtos ativos
ALTER TABLE products ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public read active products"
  ON products FOR SELECT
  USING (active = true);

CREATE POLICY "Service role full access products"
  ON products FOR ALL
  USING (auth.role() = 'service_role');

-- Dados iniciais
INSERT INTO products (name, description, price_ton, tag, sort_order, active) VALUES
  ('Master Infoprod VIP', 'Curso completo: da ideia ao produto digital que vende no piloto automático. Mais de 40 aulas.', 1.5, 'Bestseller', 1, true),
  ('Kit Lançamento Pro', 'Templates, scripts de vendas e funil completo pronto para usar imediatamente.', 3.0, 'Pack', 2, true),
  ('Sessão 1:1 Estratégica', '1 hora de mentoria exclusiva para validar e lançar o teu infoproduto.', 5.0, 'Mentoria', 3, true)
ON CONFLICT DO NOTHING;


-- ── 2. TABELA: referrals ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS referrals (
  id          BIGSERIAL   PRIMARY KEY,
  email       TEXT        NOT NULL UNIQUE,
  ref_code    TEXT        NOT NULL UNIQUE,
  clicks      INTEGER     NOT NULL DEFAULT 0,
  conversions INTEGER     NOT NULL DEFAULT 0,
  earned_ton  NUMERIC     NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index para queries rápidas
CREATE INDEX IF NOT EXISTS idx_referrals_ref_code ON referrals(ref_code);
CREATE INDEX IF NOT EXISTS idx_referrals_email    ON referrals(email);
CREATE INDEX IF NOT EXISTS idx_referrals_ranking  ON referrals(conversions DESC, earned_ton DESC);

-- RLS
ALTER TABLE referrals ENABLE ROW LEVEL SECURITY;

-- Leitura pública (para ranking — sem revelar email completo, o masking é feito no JS)
CREATE POLICY "Public read referrals for ranking"
  ON referrals FOR SELECT
  USING (true);

-- Insert via Edge Function (service_role)
CREATE POLICY "Service role full referrals"
  ON referrals FOR ALL
  USING (auth.role() = 'service_role');


-- ── 3. TABELA: orders ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS orders (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  email       TEXT        NOT NULL,
  product     TEXT        NOT NULL,
  amount      NUMERIC     NOT NULL,
  currency    TEXT        NOT NULL DEFAULT 'TON',
  invoice_id  TEXT,
  tx_boc      TEXT,
  ref_code    TEXT        REFERENCES referrals(ref_code) ON DELETE SET NULL,
  status      TEXT        NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','confirmed','failed','cancelled')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_email      ON orders(email);
CREATE INDEX IF NOT EXISTS idx_orders_invoice    ON orders(invoice_id);
CREATE INDEX IF NOT EXISTS idx_orders_status     ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders(created_at DESC);

-- RLS: utilizadores apenas veem os próprios pedidos via invoice_id + email
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- Sem acesso público direto (apenas via Edge Function com service_role)
CREATE POLICY "Service role full orders"
  ON orders FOR ALL
  USING (auth.role() = 'service_role');


-- ── 4. TABELA: ref_commissions ───────────────────────────────────
CREATE TABLE IF NOT EXISTS ref_commissions (
  id          BIGSERIAL   PRIMARY KEY,
  ref_code    TEXT        NOT NULL REFERENCES referrals(ref_code) ON DELETE CASCADE,
  product     TEXT        NOT NULL,
  invoice_id  TEXT,
  amount      NUMERIC     NOT NULL DEFAULT 0.01,
  status      TEXT        NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','paid','cancelled')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_comms_ref_code ON ref_commissions(ref_code);
CREATE INDEX IF NOT EXISTS idx_comms_status   ON ref_commissions(status);

ALTER TABLE ref_commissions ENABLE ROW LEVEL SECURITY;

-- Leitura via ref_code (utilizadores podem ver as próprias comissões)
CREATE POLICY "Read own commissions"
  ON ref_commissions FOR SELECT
  USING (true); -- filtragem por ref_code é feita na query

CREATE POLICY "Service role full commissions"
  ON ref_commissions FOR ALL
  USING (auth.role() = 'service_role');


-- ════════════════════════════════════════════════════════════════
-- FUNÇÕES ATÓMICAS (evitam race conditions)
-- ════════════════════════════════════════════════════════════════

-- Gera código de referência único garantido
CREATE OR REPLACE FUNCTION generate_unique_ref_code(p_email TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_base TEXT;
  v_code TEXT;
  v_exists BOOLEAN;
  v_attempts INTEGER := 0;
BEGIN
  -- Base: primeiros 4 chars do username (sem chars especiais)
  v_base := lower(regexp_replace(split_part(p_email, '@', 1), '[^a-z0-9]', '', 'g'));
  v_base := left(v_base, 4);
  IF length(v_base) < 2 THEN v_base := 'usr'; END IF;

  LOOP
    v_attempts := v_attempts + 1;
    -- Gera sufixo aleatório de 6 chars base36
    v_code := v_base || lower(substring(md5(p_email || now()::text || v_attempts::text) FROM 1 FOR 6));

    -- Verifica unicidade
    SELECT EXISTS(SELECT 1 FROM referrals WHERE ref_code = v_code) INTO v_exists;
    EXIT WHEN NOT v_exists;

    IF v_attempts > 20 THEN
      -- Fallback: UUID curto
      v_code := lower(substring(replace(gen_random_uuid()::text, '-', '') FROM 1 FOR 8));
      EXIT;
    END IF;
  END LOOP;

  RETURN v_code;
END;
$$;


-- Get or Create referral (atómico com lock)
CREATE OR REPLACE FUNCTION get_or_create_referral(p_email TEXT)
RETURNS referrals
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row referrals;
  v_code TEXT;
BEGIN
  -- Tenta encontrar existente
  SELECT * INTO v_row FROM referrals WHERE email = p_email FOR UPDATE;

  IF FOUND THEN
    RETURN v_row;
  END IF;

  -- Cria novo com código único
  v_code := generate_unique_ref_code(p_email);

  INSERT INTO referrals (email, ref_code, clicks, conversions, earned_ton, created_at)
  VALUES (p_email, v_code, 0, 0, 0, now())
  ON CONFLICT (email) DO UPDATE SET ref_code = referrals.ref_code -- no-op se já existe
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;


-- Incremento atómico de cliques
CREATE OR REPLACE FUNCTION increment_ref_click(p_ref_code TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE referrals
  SET clicks = clicks + 1
  WHERE ref_code = p_ref_code;
END;
$$;


-- Processar comissão de referência (atómico)
CREATE OR REPLACE FUNCTION process_ref_commission(
  p_ref_code   TEXT,
  p_product    TEXT,
  p_invoice_id TEXT,
  p_amount     NUMERIC DEFAULT 0.01
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Insere comissão
  INSERT INTO ref_commissions (ref_code, product, invoice_id, amount, status, created_at)
  VALUES (p_ref_code, p_product, p_invoice_id, p_amount, 'pending', now());

  -- Atualiza estatísticas do referenciador atomicamente
  UPDATE referrals
  SET
    conversions = conversions + 1,
    earned_ton  = earned_ton + p_amount
  WHERE ref_code = p_ref_code;
END;
$$;


-- ════════════════════════════════════════════════════════════════
-- EDGE FUNCTIONS — cria estes ficheiros em supabase/functions/
-- ════════════════════════════════════════════════════════════════
-- Instrução: corre `supabase functions deploy <nome>` para cada uma.
-- A ROCKET_TOKEN fica só aqui, NUNCA no frontend.

/*
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FILE: supabase/functions/get-or-create-referral/index.ts
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const { email } = await req.json();
    if (!email || !email.includes("@")) {
      return Response.json({ error: "Email inválido" }, { status: 400, headers: CORS });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Chama função atómica que garante código único
    const { data, error } = await supabase.rpc("get_or_create_referral", { p_email: email });
    if (error) throw error;

    return Response.json(data, { headers: CORS });
  } catch (e) {
    return Response.json({ error: e.message }, { status: 500, headers: CORS });
  }
});

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FILE: supabase/functions/increment-ref-click/index.ts
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { ref_code } = await req.json();
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { error } = await supabase.rpc("increment_ref_click", { p_ref_code: ref_code });
    if (error) throw error;
    return Response.json({ ok: true }, { headers: CORS });
  } catch (e) {
    return Response.json({ error: e.message }, { status: 500, headers: CORS });
  }
});

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FILE: supabase/functions/create-invoice/index.ts
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const ROCKET_TOKEN = Deno.env.get("ROCKET_PAY_TOKEN")!; // Definido nos secrets da Edge Function

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { amount, currency, product, email } = await req.json();

    const res = await fetch("https://pay.ton-rocket.com/app/invoices", {
      method: "POST",
      headers: { "Rocket-Pay-Key": ROCKET_TOKEN, "Content-Type": "application/json" },
      body: JSON.stringify({
        amount,
        currency,
        description: `Compra: ${product}`,
        payload: JSON.stringify({ email, product })
      })
    });

    const data = await res.json();
    if (!data.success) throw new Error(data.message || "Erro xRocket");

    return Response.json({
      id:      data.data.id,
      address: data.data.address,
      payload: data.data.payload
    }, { headers: CORS });
  } catch (e) {
    return Response.json({ error: e.message }, { status: 500, headers: CORS });
  }
});

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FILE: supabase/functions/process-order/index.ts
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const REF_REWARD = 0.01;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { email, product, amount, currency, invoice_id, tx_boc, ref_code } = await req.json();

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Insere order
    const { error: orderErr } = await supabase.from("orders").insert({
      email, product, amount, currency, invoice_id, tx_boc,
      ref_code: ref_code || null,
      status: "pending",
      created_at: new Date().toISOString()
    });
    if (orderErr) throw orderErr;

    // Processa comissão de referência (atómico)
    if (ref_code) {
      const { error: commErr } = await supabase.rpc("process_ref_commission", {
        p_ref_code:   ref_code,
        p_product:    product,
        p_invoice_id: invoice_id,
        p_amount:     REF_REWARD
      });
      if (commErr) console.error("Comissão:", commErr.message);
    }

    return Response.json({ ok: true }, { headers: CORS });
  } catch (e) {
    return Response.json({ error: e.message }, { status: 500, headers: CORS });
  }
});

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COMANDOS PARA DEPLOY DAS EDGE FUNCTIONS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  supabase login
  supabase link --project-ref tgslxwhmjbdkgwljhyxp

  # Definir secrets (nunca no código!)
  supabase secrets set ROCKET_PAY_TOKEN=2b95ea2ad1f9a2d53563a05d4

  # Deploy de todas as funções
  supabase functions deploy get-or-create-referral
  supabase functions deploy increment-ref-click
  supabase functions deploy create-invoice
  supabase functions deploy process-order

*/
