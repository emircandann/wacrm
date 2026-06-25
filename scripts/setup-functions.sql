-- ============================================================
-- Fresh PostgreSQL setup: extensions, functions, triggers.
-- Safe to re-run (idempotent).
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- handle_new_user — bootstrap account + owner profile on signup
-- ============================================================
DROP TRIGGER IF EXISTS on_auth_user_created ON public.users;
DROP TRIGGER IF EXISTS on_user_created ON public.users;
DROP FUNCTION IF EXISTS public.handle_new_user() CASCADE;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_account_id UUID;
BEGIN
  IF EXISTS (SELECT 1 FROM public.profiles WHERE user_id = NEW.id) THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.accounts (name, owner_user_id)
  VALUES (COALESCE(NEW.email, 'My account'), NEW.id)
  RETURNING id INTO v_account_id;

  INSERT INTO public.profiles (user_id, full_name, email, account_id, account_role)
  VALUES (NEW.id, COALESCE(NEW.email, ''), NEW.email, v_account_id, 'owner');

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Failed to bootstrap account/profile for user %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_user_created
  AFTER INSERT ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================
-- touch_presence(p_caller_id, p_status)
-- ============================================================
DROP FUNCTION IF EXISTS public.touch_presence(TEXT);
DROP FUNCTION IF EXISTS public.touch_presence(UUID, TEXT);

CREATE OR REPLACE FUNCTION public.touch_presence(
  p_caller_id UUID,
  p_status TEXT DEFAULT 'online'
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_account_id UUID;
BEGIN
  IF p_caller_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  IF p_status NOT IN ('online', 'away') THEN
    RAISE EXCEPTION 'Invalid presence status: %', p_status USING ERRCODE = '22023';
  END IF;

  SELECT account_id INTO v_account_id FROM profiles WHERE user_id = p_caller_id;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'No account for caller' USING ERRCODE = '22023';
  END IF;

  INSERT INTO member_presence (user_id, account_id, status, last_seen_at)
  VALUES (p_caller_id, v_account_id, p_status, now())
  ON CONFLICT (user_id) DO UPDATE
    SET status       = excluded.status,
        last_seen_at = now(),
        account_id   = excluded.account_id;
END;
$$;

-- ============================================================
-- set_member_role(p_caller_id, p_user_id, p_new_role)
-- ============================================================
DROP FUNCTION IF EXISTS public.set_member_role(UUID, account_role_enum);
DROP FUNCTION IF EXISTS public.set_member_role(UUID, UUID, account_role_enum);

CREATE OR REPLACE FUNCTION public.set_member_role(
  p_caller_id UUID,
  p_user_id UUID,
  p_new_role account_role_enum
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_caller_account_id UUID;
  v_caller_role account_role_enum;
  v_target_account_id UUID;
  v_target_role account_role_enum;
BEGIN
  IF p_caller_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT account_id, account_role INTO v_caller_account_id, v_caller_role
  FROM profiles WHERE user_id = p_caller_id;

  IF v_caller_account_id IS NULL THEN
    RAISE EXCEPTION 'Caller has no account' USING ERRCODE = '42501';
  END IF;

  IF v_caller_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'This action requires the admin role or higher' USING ERRCODE = '42501';
  END IF;

  IF p_user_id = p_caller_id THEN
    RAISE EXCEPTION 'Cannot change your own role' USING ERRCODE = '22023';
  END IF;

  SELECT account_id, account_role INTO v_target_account_id, v_target_role
  FROM profiles WHERE user_id = p_user_id;

  IF v_target_account_id IS NULL THEN
    RAISE EXCEPTION 'Target user not found' USING ERRCODE = '22023';
  END IF;

  IF v_target_account_id <> v_caller_account_id THEN
    RAISE EXCEPTION 'Target user is not a member of your account' USING ERRCODE = '42501';
  END IF;

  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'Use transfer_account_ownership to demote an owner' USING ERRCODE = '22023';
  END IF;
  IF p_new_role = 'owner' THEN
    RAISE EXCEPTION 'Use transfer_account_ownership to promote to owner' USING ERRCODE = '22023';
  END IF;

  UPDATE profiles SET account_role = p_new_role WHERE user_id = p_user_id;
END;
$$;

-- ============================================================
-- remove_account_member(p_caller_id, p_user_id)
-- ============================================================
DROP FUNCTION IF EXISTS public.remove_account_member(UUID);
DROP FUNCTION IF EXISTS public.remove_account_member(UUID, UUID);

CREATE OR REPLACE FUNCTION public.remove_account_member(
  p_caller_id UUID,
  p_user_id UUID
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_caller_account_id UUID;
  v_caller_role account_role_enum;
  v_target_account_id UUID;
  v_target_role account_role_enum;
  v_target_name TEXT;
  v_target_email TEXT;
  v_new_account_id UUID;
BEGIN
  IF p_caller_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT account_id, account_role INTO v_caller_account_id, v_caller_role
  FROM profiles WHERE user_id = p_caller_id;

  IF v_caller_account_id IS NULL THEN
    RAISE EXCEPTION 'Caller has no account' USING ERRCODE = '42501';
  END IF;

  IF v_caller_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'This action requires the admin role or higher' USING ERRCODE = '42501';
  END IF;

  IF p_user_id = p_caller_id THEN
    RAISE EXCEPTION 'Cannot remove yourself; transfer ownership or leave the account instead' USING ERRCODE = '22023';
  END IF;

  SELECT account_id, account_role, full_name, email
  INTO v_target_account_id, v_target_role, v_target_name, v_target_email
  FROM profiles WHERE user_id = p_user_id;

  IF v_target_account_id IS NULL THEN
    RAISE EXCEPTION 'Target user not found' USING ERRCODE = '22023';
  END IF;

  IF v_target_account_id <> v_caller_account_id THEN
    RAISE EXCEPTION 'Target user is not a member of your account' USING ERRCODE = '42501';
  END IF;

  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'Cannot remove the account owner; transfer ownership first' USING ERRCODE = '22023';
  END IF;

  INSERT INTO accounts (name, owner_user_id)
  VALUES (COALESCE(NULLIF(v_target_name, ''), v_target_email, 'My account'), p_user_id)
  RETURNING id INTO v_new_account_id;

  UPDATE profiles
  SET account_id = v_new_account_id, account_role = 'owner'
  WHERE user_id = p_user_id;

  RETURN v_new_account_id;
END;
$$;

-- ============================================================
-- transfer_account_ownership(p_caller_id, p_new_owner_user_id)
-- ============================================================
DROP FUNCTION IF EXISTS public.transfer_account_ownership(UUID);
DROP FUNCTION IF EXISTS public.transfer_account_ownership(UUID, UUID);

CREATE OR REPLACE FUNCTION public.transfer_account_ownership(
  p_caller_id UUID,
  p_new_owner_user_id UUID
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_caller_account_id UUID;
  v_caller_role account_role_enum;
  v_target_account_id UUID;
BEGIN
  IF p_caller_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT account_id, account_role INTO v_caller_account_id, v_caller_role
  FROM profiles WHERE user_id = p_caller_id;

  IF v_caller_account_id IS NULL THEN
    RAISE EXCEPTION 'Caller has no account' USING ERRCODE = '42501';
  END IF;

  IF v_caller_role <> 'owner' THEN
    RAISE EXCEPTION 'Only the account owner can transfer ownership' USING ERRCODE = '42501';
  END IF;

  IF p_new_owner_user_id = p_caller_id THEN
    RAISE EXCEPTION 'You are already the owner' USING ERRCODE = '22023';
  END IF;

  SELECT account_id INTO v_target_account_id
  FROM profiles WHERE user_id = p_new_owner_user_id;

  IF v_target_account_id IS NULL THEN
    RAISE EXCEPTION 'Target user not found' USING ERRCODE = '22023';
  END IF;

  IF v_target_account_id <> v_caller_account_id THEN
    RAISE EXCEPTION 'Target user is not a member of your account' USING ERRCODE = '42501';
  END IF;

  UPDATE profiles SET account_role = 'admin' WHERE user_id = p_caller_id;
  UPDATE profiles SET account_role = 'owner' WHERE user_id = p_new_owner_user_id;
  UPDATE accounts SET owner_user_id = p_new_owner_user_id WHERE id = v_caller_account_id;
END;
$$;

-- ============================================================
-- notify_realtime — pg_notify trigger for SSE endpoint
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_realtime()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_row JSONB;
  v_account_id UUID;
  v_payload JSONB;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_row := to_jsonb(OLD);
  ELSE
    v_row := to_jsonb(NEW);
  END IF;

  v_account_id := NULLIF(v_row->>'account_id', '')::UUID;

  v_payload := jsonb_build_object(
    'table', TG_TABLE_NAME,
    'op', TG_OP,
    'id', v_row->>'id',
    'account_id', v_account_id,
    'conversation_id', v_row->>'conversation_id'
  );

  PERFORM pg_notify('wacrm_realtime', v_payload::text);

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS notify_messages ON public.messages;
CREATE TRIGGER notify_messages
  AFTER INSERT OR UPDATE OR DELETE ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.notify_realtime();

DROP TRIGGER IF EXISTS notify_conversations ON public.conversations;
CREATE TRIGGER notify_conversations
  AFTER INSERT OR UPDATE OR DELETE ON public.conversations
  FOR EACH ROW EXECUTE FUNCTION public.notify_realtime();

DROP TRIGGER IF EXISTS notify_member_presence ON public.member_presence;
CREATE TRIGGER notify_member_presence
  AFTER INSERT OR UPDATE OR DELETE ON public.member_presence
  FOR EACH ROW EXECUTE FUNCTION public.notify_realtime();

-- ============================================================
-- peek_invitation(p_token_hash) — anonymous invite lookup
-- ============================================================
CREATE OR REPLACE FUNCTION public.peek_invitation(
  p_token_hash TEXT
) RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inv account_invitations%ROWTYPE;
  v_account_name TEXT;
BEGIN
  SELECT * INTO v_inv
  FROM account_invitations
  WHERE token_hash = p_token_hash;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_inv.accepted_at IS NOT NULL THEN
    RETURN json_build_object('ok', false, 'reason', 'used');
  END IF;

  IF v_inv.expires_at <= NOW() THEN
    RETURN json_build_object('ok', false, 'reason', 'expired');
  END IF;

  SELECT name INTO v_account_name
  FROM accounts
  WHERE id = v_inv.account_id;

  RETURN json_build_object(
    'ok', true,
    'account_name', v_account_name,
    'role', v_inv.role,
    'expires_at', v_inv.expires_at
  );
END;
$$;
