--
-- PostgreSQL database dump
--

\restrict Tw2HrqUWyY6NehtCBbQ0KeGOlD3odK9c0LJ3DH7w2Tn1L7EI6NYYWLMN1XFDBCX

-- Dumped from database version 16.14 (Debian 16.14-1.pgdg13+1)
-- Dumped by pg_dump version 16.15

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

--
-- Name: event_store_delete(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.event_store_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  message text;
BEGIN
  IF current_setting('eventstore.enable_hard_deletes', true) = 'on' OR
    current_setting('eventstore.reset', true) = 'on'
  THEN
    -- Allow DELETE
    RETURN OLD;
  ELSE
    -- Prevent DELETE
    message := 'EventStore: ' || TG_ARGV[0];

    RAISE EXCEPTION USING MESSAGE = message, ERRCODE = 'feature_not_supported';
  END IF;
END;
$$;


ALTER FUNCTION public.event_store_delete() OWNER TO postgres;

--
-- Name: event_store_exception(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.event_store_exception() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  message text;
BEGIN
  message := 'EventStore: ' || TG_ARGV[0];

  RAISE EXCEPTION USING MESSAGE = message;
END;
$$;


ALTER FUNCTION public.event_store_exception() OWNER TO postgres;

--
-- Name: notify_events(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.notify_events() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  old_stream_version bigint;
  channel text;
  payload text;
BEGIN
    -- Payload text contains:
    --  * `stream_uuid`
    --  * `stream_id`
    --  * first `stream_version`
    --  * last `stream_version`
    -- Each separated by a comma (e.g. 'stream-12345,1,1,5')

    IF TG_OP = 'UPDATE' THEN
      old_stream_version := OLD.stream_version + 1;
    ELSE
      old_stream_version := 1;
    END IF;

    channel := TG_TABLE_SCHEMA || '.events';
    payload := NEW.stream_uuid || ',' || NEW.stream_id || ',' || old_stream_version || ',' || NEW.stream_version;

    -- Notify events to listeners
    PERFORM pg_notify(channel, payload);

    RETURN NULL;
END;
$$;


ALTER FUNCTION public.notify_events() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.events (
    event_id uuid NOT NULL,
    event_type text NOT NULL,
    causation_id uuid,
    correlation_id uuid,
    data bytea NOT NULL,
    metadata bytea,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.events OWNER TO postgres;

--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.schema_migrations (
    major_version integer NOT NULL,
    minor_version integer NOT NULL,
    patch_version integer NOT NULL,
    migrated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.schema_migrations OWNER TO postgres;

--
-- Name: snapshots; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.snapshots (
    source_uuid text NOT NULL,
    source_version bigint NOT NULL,
    source_type text NOT NULL,
    data bytea NOT NULL,
    metadata bytea,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.snapshots OWNER TO postgres;

--
-- Name: stream_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.stream_events (
    event_id uuid NOT NULL,
    stream_id bigint NOT NULL,
    stream_version bigint NOT NULL,
    original_stream_id bigint,
    original_stream_version bigint
);


ALTER TABLE public.stream_events OWNER TO postgres;

--
-- Name: streams; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.streams (
    stream_id bigint NOT NULL,
    stream_uuid text NOT NULL,
    stream_version bigint DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


ALTER TABLE public.streams OWNER TO postgres;

--
-- Name: streams_stream_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.streams_stream_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.streams_stream_id_seq OWNER TO postgres;

--
-- Name: streams_stream_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.streams_stream_id_seq OWNED BY public.streams.stream_id;


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.subscriptions (
    subscription_id bigint NOT NULL,
    stream_uuid text NOT NULL,
    subscription_name text NOT NULL,
    last_seen bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.subscriptions OWNER TO postgres;

--
-- Name: subscriptions_subscription_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.subscriptions_subscription_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.subscriptions_subscription_id_seq OWNER TO postgres;

--
-- Name: subscriptions_subscription_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.subscriptions_subscription_id_seq OWNED BY public.subscriptions.subscription_id;


--
-- Name: streams stream_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.streams ALTER COLUMN stream_id SET DEFAULT nextval('public.streams_stream_id_seq'::regclass);


--
-- Name: subscriptions subscription_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.subscriptions ALTER COLUMN subscription_id SET DEFAULT nextval('public.subscriptions_subscription_id_seq'::regclass);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (event_id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (major_version, minor_version, patch_version);


--
-- Name: snapshots snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.snapshots
    ADD CONSTRAINT snapshots_pkey PRIMARY KEY (source_uuid);


--
-- Name: stream_events stream_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stream_events
    ADD CONSTRAINT stream_events_pkey PRIMARY KEY (event_id, stream_id);


--
-- Name: streams streams_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.streams
    ADD CONSTRAINT streams_pkey PRIMARY KEY (stream_id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (subscription_id);


--
-- Name: ix_stream_events; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX ix_stream_events ON public.stream_events USING btree (stream_id, stream_version);


--
-- Name: ix_streams_stream_uuid; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX ix_streams_stream_uuid ON public.streams USING btree (stream_uuid);


--
-- Name: ix_subscriptions_stream_uuid_subscription_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX ix_subscriptions_stream_uuid_subscription_name ON public.subscriptions USING btree (stream_uuid, subscription_name);


--
-- Name: streams event_notification; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER event_notification AFTER INSERT OR UPDATE ON public.streams FOR EACH ROW EXECUTE FUNCTION public.notify_events();


--
-- Name: events no_delete_events; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER no_delete_events BEFORE DELETE ON public.events FOR EACH STATEMENT EXECUTE FUNCTION public.event_store_delete('Cannot delete events');


--
-- Name: stream_events no_delete_stream_events; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER no_delete_stream_events BEFORE DELETE ON public.stream_events FOR EACH STATEMENT EXECUTE FUNCTION public.event_store_delete('Cannot delete stream events');


--
-- Name: streams no_delete_streams; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER no_delete_streams BEFORE DELETE ON public.streams FOR EACH STATEMENT EXECUTE FUNCTION public.event_store_delete('Cannot delete streams');


--
-- Name: events no_update_events; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER no_update_events BEFORE UPDATE ON public.events FOR EACH STATEMENT EXECUTE FUNCTION public.event_store_exception('Cannot update events');


--
-- Name: stream_events no_update_stream_events; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER no_update_stream_events BEFORE UPDATE ON public.stream_events FOR EACH STATEMENT EXECUTE FUNCTION public.event_store_exception('Cannot update stream events');


--
-- Name: stream_events stream_events_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stream_events
    ADD CONSTRAINT stream_events_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.events(event_id);


--
-- Name: stream_events stream_events_original_stream_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stream_events
    ADD CONSTRAINT stream_events_original_stream_id_fkey FOREIGN KEY (original_stream_id) REFERENCES public.streams(stream_id);


--
-- Name: stream_events stream_events_stream_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.stream_events
    ADD CONSTRAINT stream_events_stream_id_fkey FOREIGN KEY (stream_id) REFERENCES public.streams(stream_id);


--
-- PostgreSQL database dump complete
--

\unrestrict Tw2HrqUWyY6NehtCBbQ0KeGOlD3odK9c0LJ3DH7w2Tn1L7EI6NYYWLMN1XFDBCX

