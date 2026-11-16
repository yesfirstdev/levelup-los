/** Tests the actual API boundary, not just SQL grants: policy helpers have SQL
 * execute rights for RLS but must be unreachable via RPC, even after sign-in.
 * Local seeded database only; fixtures are removed afterwards. */
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { adminClient, must } from "./admin";

const URL_ = import.meta.env.VITE_SUPABASE_URL as string;
const KEY = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
const WS = "security-private-helper-team";
const PERSON = "security-private-helper-person";
const options = {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
    detectSessionInUrl: false,
  },
};
const anon = createClient(URL_, KEY, options);
const member = createClient(URL_, KEY, options);
const rawLookups: [string, Record<string, string>][] = [
  ["board_columns", { p_board: "recruiting", p_owner: PERSON }],
  ["board_column_ord", { p_board: "recruiting", p_owner: "4", p_column: "foreign-step" }],
  [
    "booking_kept",
    { p_board: "recruiting", p_owner: "4", p_booked: "foreign-step", p_to: "contact" },
  ],
  ["can_own_list", { p_person_id: PERSON }],
  ["chat_eligible", { p_person_id: PERSON }],
  ["conversation_kind", { p_conversation_id: "main" }],
  ["conversation_workspace", { p_conversation_id: "main" }],
  ["cost_owner", { p_cost_id: "cost1" }],
  ["cost_workspace", { p_cost_id: "cost1" }],
  ["customer_move_is_latest", { p_move_id: "move1" }],
  ["dm_other_person", { p_conversation_id: "dm-1-2" }],
  ["downline_ids", { p_root: PERSON }],
  ["event_workspace", { p_event_id: "e1" }],
  ["has_paid", { p_cost_id: "cost1", p_person_id: PERSON }],
  ["is_team_chat", { p_conversation_id: "main" }],
  ["message_author_id", { p_message_id: "message1" }],
  ["message_conversation_id", { p_message_id: "message1" }],
  ["person_workspace", { p_person_id: PERSON }],
  ["pipeline_move_is_latest", { p_move_id: "move1" }],
  ["workspace_today", { p_workspace_id: WS }],
  ["step_card_owner", { p_board: "recruiting", p_card_id: PERSON }],
  ["dm_open", { p_conversation_id: "dm-1-2" }],
];

beforeAll(async () => {
  await must(
    adminClient().from("workspaces").insert({ id: WS, name: "Isolated security team" }),
    "security workspace",
  );
  await must(
    adminClient().from("people").insert({
      id: PERSON,
      workspace_id: WS,
      name: "Unrelated person",
      biz_class: "ibo",
      business_start_date: "2020-01-01",
    }),
    "security person",
  );
  const { error } = await member.auth.signInWithPassword({
    email: "jamal@demo.test",
    password: "demo-local",
  });
  if (error) throw error;
});

afterAll(async () => {
  await member.auth.signOut({ scope: "local" });
  await must(adminClient().from("people").delete().eq("id", PERSON), "security person");
  await must(adminClient().from("workspaces").delete().eq("id", WS), "security workspace");
});

async function assertHidden(client: SupabaseClient) {
  for (const [name, args] of rawLookups) {
    const result = await client.rpc(name, args);
    expect(result.error?.code, name).toBe("PGRST202");
    expect(result.data, name).toBeNull();
  }
  const privateCall = await client
    .schema("app_private")
    .rpc("person_workspace", { p_person_id: PERSON });
  expect(privateCall.error?.code).toBe("PGRST106");
  expect(privateCall.data).toBeNull();
}

describe("internal helper API isolation", () => {
  it("anonymous API callers cannot query any raw helper or private schema", async () => {
    await assertHidden(anon);
    const result = await anon.rpc("pair_includes_caller", { a: "1", b: "2" });
    expect(result.error).not.toBeNull();
    expect(result.data).toBeNull();
  });
  it("signed-in callers cannot bypass cross-tenant RLS through helper RPCs", async () => {
    const result = await member.from("people").select("id").eq("id", PERSON);
    expect(result.error).toBeNull();
    expect(result.data).toEqual([]);
    await assertHidden(member);
  });
  it("legitimate sign-in, scoped directory and sponsor-chain RPC still work", async () => {
    const session = await member.rpc("get_session");
    expect(session.error).toBeNull();
    expect(session.data).not.toBeNull();
    const chain = await member.rpc("sponsor_chain", { p_person_id: "4" });
    expect(chain.error).toBeNull();
    expect(chain.data.some((row: { person_id: string }) => row.person_id === "4")).toBe(true);
    const directory = await member.from("chat_directory").select("person_id");
    expect(directory.error).toBeNull();
    expect(directory.data?.some((row) => row.person_id === "4")).toBe(true);
    expect(directory.data?.some((row) => row.person_id === PERSON)).toBe(false);
  });
  it("anonymous token-based invite preview remains callable", async () => {
    const result = await anon.rpc("get_invite", {
      p_token: "security-nonexistent-token",
    });
    expect(result.error).toBeNull();
    expect(result.data).toEqual([]);
  });
});
