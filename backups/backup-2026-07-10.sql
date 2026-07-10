


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."txn_type" AS ENUM (
    'PRVS',
    'RCVD',
    'DLVD'
);


ALTER TYPE "public"."txn_type" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_transaction"("txn_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
declare
  txn record;
  r record;
  running_stock numeric := 0;
  running_value numeric := 0;
  v_qty numeric;
  v_price numeric;
  v_line_value numeric;
begin
  select * into txn from transactions where id = txn_id;
  if txn is null then
    raise exception 'Transaction not found';
  end if;

  delete from transactions where id = txn_id;

  for r in
    select id, type, qty, unit_price_snapshot
    from transactions
    where item_id = txn.item_id
    order by txn_date asc, created_at asc
  loop
    v_qty := coalesce(r.qty, 0);
    v_price := coalesce(r.unit_price_snapshot, 0);
    v_line_value := v_qty * v_price;

    if r.type in ('PRVS', 'RCVD') then
      running_stock := running_stock + v_qty;
      running_value := running_value + v_line_value;
    elsif r.type = 'DLVD' then
      running_stock := running_stock - v_qty;
      running_value := running_value - v_line_value;
    end if;

    -- line_value বাদ, generated column, database নিজেই বানায়
    update transactions
    set present_stock_after = running_stock,
        stock_value_after = running_value
    where id = r.id;
  end loop;

  update items
  set current_stock = running_stock,
      current_value = running_value
  where id = txn.item_id;
end;
$$;


ALTER FUNCTION "public"."delete_transaction"("txn_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_apply_transaction"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
    v_stock numeric(14,3);
    v_value numeric(14,3);
begin
    -- RCVD হলে challan অনুযায়ী MRR বসানো (challan একই থাকলে MRR একই থাকবে)
    if new.type = 'RCVD' and new.challan_no is not null then
        new.mrr_no := get_or_create_mrr(new.challan_no);
    end if;

    -- বর্তমান স্টক হিসাব
    select current_stock, current_value into v_stock, v_value
    from items where id = new.item_id;

    if new.type = 'PRVS' then
        v_stock := new.qty;
    elsif new.type = 'RCVD' then
        v_stock := v_stock + new.qty;
    elsif new.type = 'DLVD' then
        v_stock := v_stock - new.qty;
    end if;

    v_value := v_stock * new.unit_price_snapshot;

    new.present_stock_after := v_stock;
    new.stock_value_after   := v_value;

    return new;
end;
$$;


ALTER FUNCTION "public"."fn_apply_transaction"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_update_item_after_txn"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
    update items
    set current_stock = new.present_stock_after,
        current_value = new.stock_value_after,
        last_txn_date = new.txn_date,
        updated_at    = now()
    where id = new.item_id;
    return new;
end;
$$;


ALTER FUNCTION "public"."fn_update_item_after_txn"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_or_create_mrr"("p_challan_no" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
    v_mrr text;
begin
    select mrr_no into v_mrr from challan_mrr where challan_no = p_challan_no;
    if v_mrr is null then
        v_mrr := next_mrr_no();
        insert into challan_mrr(challan_no, mrr_no) values (p_challan_no, v_mrr);
    end if;
    return v_mrr;
end;
$$;


ALTER FUNCTION "public"."get_or_create_mrr"("p_challan_no" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_mrr_no"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
    yy text := to_char(now(), 'YY');
    n  bigint;
begin
    n := nextval('mrr_seq');
    return 'ACC-MRR-' || yy || '-' || lpad(n::text, 4, '0');
end;
$$;


ALTER FUNCTION "public"."next_mrr_no"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."buyers" (
    "id" bigint NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."buyers" OWNER TO "postgres";


ALTER TABLE "public"."buyers" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."buyers_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."challan_mrr" (
    "id" bigint NOT NULL,
    "challan_no" "text" NOT NULL,
    "mrr_no" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."challan_mrr" OWNER TO "postgres";


ALTER TABLE "public"."challan_mrr" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."challan_mrr_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."items" (
    "id" bigint NOT NULL,
    "buyer_id" bigint NOT NULL,
    "description" "text" NOT NULL,
    "unit" "text" NOT NULL,
    "unit_price" numeric(12,4) DEFAULT 0 NOT NULL,
    "goods_location" "text",
    "supplier" "text",
    "stock_type" "text",
    "item_code" "text" NOT NULL,
    "qr_payload" "text" NOT NULL,
    "current_stock" numeric(14,3) DEFAULT 0 NOT NULL,
    "current_value" numeric(14,3) DEFAULT 0 NOT NULL,
    "last_txn_date" "date",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."items" OWNER TO "postgres";


ALTER TABLE "public"."items" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE SEQUENCE IF NOT EXISTS "public"."mrr_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."mrr_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."team_members" (
    "id" bigint NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."team_members" OWNER TO "postgres";


ALTER TABLE "public"."team_members" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."team_members_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."transactions" (
    "id" bigint NOT NULL,
    "item_id" bigint NOT NULL,
    "type" "public"."txn_type" NOT NULL,
    "txn_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "order_no" "text",
    "style_no" "text",
    "qc_status" "text",
    "rejected_qty" numeric(14,3) DEFAULT 0,
    "return_qty" numeric(14,3) DEFAULT 0,
    "approval_status" "text",
    "qty" numeric(14,3) DEFAULT 0 NOT NULL,
    "unit_price_snapshot" numeric(12,4) DEFAULT 0 NOT NULL,
    "line_value" numeric(14,3) GENERATED ALWAYS AS (("qty" * "unit_price_snapshot")) STORED,
    "challan_no" "text",
    "mrr_no" "text",
    "present_stock_after" numeric(14,3),
    "stock_value_after" numeric(14,3),
    "team_member_id" bigint,
    "remarks" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "lc_pi_no" "text",
    "supplier" "text"
);


ALTER TABLE "public"."transactions" OWNER TO "postgres";


ALTER TABLE "public"."transactions" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."transactions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."v_ageing" AS
 SELECT "i"."id" AS "item_id",
    "i"."item_code",
    "b"."name" AS "buyer",
    "i"."description",
    "i"."current_stock",
    "i"."current_value",
    "i"."last_txn_date",
    (CURRENT_DATE - "i"."last_txn_date") AS "age_days",
        CASE
            WHEN (((CURRENT_DATE - "i"."last_txn_date") >= 0) AND ((CURRENT_DATE - "i"."last_txn_date") <= 30)) THEN '1-30 Days'::"text"
            WHEN (((CURRENT_DATE - "i"."last_txn_date") >= 31) AND ((CURRENT_DATE - "i"."last_txn_date") <= 60)) THEN '31-60 Days'::"text"
            WHEN (((CURRENT_DATE - "i"."last_txn_date") >= 61) AND ((CURRENT_DATE - "i"."last_txn_date") <= 90)) THEN '61-90 Days'::"text"
            WHEN (((CURRENT_DATE - "i"."last_txn_date") >= 91) AND ((CURRENT_DATE - "i"."last_txn_date") <= 120)) THEN '91-120 Days'::"text"
            WHEN (((CURRENT_DATE - "i"."last_txn_date") >= 121) AND ((CURRENT_DATE - "i"."last_txn_date") <= 150)) THEN '121-150 Days'::"text"
            WHEN (((CURRENT_DATE - "i"."last_txn_date") >= 151) AND ((CURRENT_DATE - "i"."last_txn_date") <= 180)) THEN '151-180 Days'::"text"
            ELSE '181>365 Days'::"text"
        END AS "ageing_category"
   FROM ("public"."items" "i"
     JOIN "public"."buyers" "b" ON (("b"."id" = "i"."buyer_id")));


ALTER VIEW "public"."v_ageing" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_scan_lookup" AS
 SELECT "i"."id" AS "item_id",
    "i"."item_code",
    "i"."qr_payload",
    "b"."name" AS "buyer",
    "i"."description",
    "i"."unit",
    "i"."unit_price",
    "i"."current_stock",
    "i"."current_value",
    "i"."last_txn_date"
   FROM ("public"."items" "i"
     JOIN "public"."buyers" "b" ON (("b"."id" = "i"."buyer_id")));


ALTER VIEW "public"."v_scan_lookup" OWNER TO "postgres";


ALTER TABLE ONLY "public"."buyers"
    ADD CONSTRAINT "buyers_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."buyers"
    ADD CONSTRAINT "buyers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."challan_mrr"
    ADD CONSTRAINT "challan_mrr_challan_no_key" UNIQUE ("challan_no");



ALTER TABLE ONLY "public"."challan_mrr"
    ADD CONSTRAINT "challan_mrr_mrr_no_key" UNIQUE ("mrr_no");



ALTER TABLE ONLY "public"."challan_mrr"
    ADD CONSTRAINT "challan_mrr_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_buyer_id_description_key" UNIQUE ("buyer_id", "description");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_item_code_key" UNIQUE ("item_code");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_qr_payload_key" UNIQUE ("qr_payload");



ALTER TABLE ONLY "public"."team_members"
    ADD CONSTRAINT "team_members_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."team_members"
    ADD CONSTRAINT "team_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_items_buyer" ON "public"."items" USING "btree" ("buyer_id");



CREATE INDEX "idx_items_code" ON "public"."items" USING "btree" ("item_code");



CREATE INDEX "idx_txn_challan" ON "public"."transactions" USING "btree" ("challan_no");



CREATE INDEX "idx_txn_date" ON "public"."transactions" USING "btree" ("txn_date");



CREATE INDEX "idx_txn_item" ON "public"."transactions" USING "btree" ("item_id");



CREATE INDEX "idx_txn_mrr" ON "public"."transactions" USING "btree" ("mrr_no");



CREATE INDEX "idx_txn_type" ON "public"."transactions" USING "btree" ("type");



CREATE OR REPLACE TRIGGER "trg_apply_transaction" BEFORE INSERT OR UPDATE ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."fn_apply_transaction"();



CREATE OR REPLACE TRIGGER "trg_update_item_after_txn" AFTER INSERT OR UPDATE ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."fn_update_item_after_txn"();



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_buyer_id_fkey" FOREIGN KEY ("buyer_id") REFERENCES "public"."buyers"("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."items"("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_team_member_id_fkey" FOREIGN KEY ("team_member_id") REFERENCES "public"."team_members"("id");



CREATE POLICY "allow all - buyers" ON "public"."buyers" USING (true) WITH CHECK (true);



CREATE POLICY "allow all - challan_mrr" ON "public"."challan_mrr" USING (true) WITH CHECK (true);



CREATE POLICY "allow all - items" ON "public"."items" USING (true) WITH CHECK (true);



CREATE POLICY "allow all - team_members" ON "public"."team_members" USING (true) WITH CHECK (true);



CREATE POLICY "allow all - transactions" ON "public"."transactions" USING (true) WITH CHECK (true);



ALTER TABLE "public"."buyers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."challan_mrr" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."team_members" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transactions" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."delete_transaction"("txn_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."delete_transaction"("txn_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_transaction"("txn_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_apply_transaction"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_apply_transaction"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_apply_transaction"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_update_item_after_txn"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_update_item_after_txn"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_update_item_after_txn"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_or_create_mrr"("p_challan_no" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_or_create_mrr"("p_challan_no" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_or_create_mrr"("p_challan_no" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."next_mrr_no"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_mrr_no"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_mrr_no"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";


















GRANT ALL ON TABLE "public"."buyers" TO "anon";
GRANT ALL ON TABLE "public"."buyers" TO "authenticated";
GRANT ALL ON TABLE "public"."buyers" TO "service_role";



GRANT ALL ON SEQUENCE "public"."buyers_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."buyers_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."buyers_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."challan_mrr" TO "anon";
GRANT ALL ON TABLE "public"."challan_mrr" TO "authenticated";
GRANT ALL ON TABLE "public"."challan_mrr" TO "service_role";



GRANT ALL ON SEQUENCE "public"."challan_mrr_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."challan_mrr_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."challan_mrr_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."items" TO "anon";
GRANT ALL ON TABLE "public"."items" TO "authenticated";
GRANT ALL ON TABLE "public"."items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."items_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mrr_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mrr_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mrr_seq" TO "service_role";



GRANT ALL ON TABLE "public"."team_members" TO "anon";
GRANT ALL ON TABLE "public"."team_members" TO "authenticated";
GRANT ALL ON TABLE "public"."team_members" TO "service_role";



GRANT ALL ON SEQUENCE "public"."team_members_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."team_members_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."team_members_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."transactions" TO "anon";
GRANT ALL ON TABLE "public"."transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."transactions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."transactions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."transactions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."transactions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."v_ageing" TO "anon";
GRANT ALL ON TABLE "public"."v_ageing" TO "authenticated";
GRANT ALL ON TABLE "public"."v_ageing" TO "service_role";



GRANT ALL ON TABLE "public"."v_scan_lookup" TO "anon";
GRANT ALL ON TABLE "public"."v_scan_lookup" TO "authenticated";
GRANT ALL ON TABLE "public"."v_scan_lookup" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































