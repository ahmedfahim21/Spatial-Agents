// deno test supabase/functions/chat/routing_test.ts
import { deepStrictEqual } from "node:assert/strict";
import { routeFor, TRUST_MODE_HEADER } from "./routing.ts";

const defaults = { model: "claude-haiku-5.5", privateModel: "0gm-1.0-35b-a3b" };

Deno.test("an ordinary agent on the default model has no header and no fallback", () => {
  deepStrictEqual(routeFor({ model: null, private_inference: false }, defaults), {
    model: "claude-haiku-5.5", headers: {}, fallback: null, private: false,
  });
});

Deno.test("an ordinary agent that names the default model is treated the same", () => {
  deepStrictEqual(routeFor({ model: "claude-haiku-5.5", private_inference: false }, defaults), {
    model: "claude-haiku-5.5", headers: {}, fallback: null, private: false,
  });
});

Deno.test("an ordinary agent with its own model can fall back to the default", () => {
  deepStrictEqual(routeFor({ model: "gpt-5.4-mini", private_inference: false }, defaults), {
    model: "gpt-5.4-mini", headers: {}, fallback: "claude-haiku-5.5", private: false,
  });
});

Deno.test("a private agent with no model gets the private default, the trust header and no fallback", () => {
  deepStrictEqual(routeFor({ model: null, private_inference: true }, defaults), {
    model: "0gm-1.0-35b-a3b", headers: { [TRUST_MODE_HEADER]: "private" }, fallback: null, private: true,
  });
});

Deno.test("a private agent left on the default model moves to the private default", () => {
  deepStrictEqual(routeFor({ model: "claude-haiku-5.5", private_inference: true }, defaults), {
    model: "0gm-1.0-35b-a3b", headers: { [TRUST_MODE_HEADER]: "private" }, fallback: null, private: true,
  });
});

Deno.test("a private agent keeps its chosen model, and never gets a fallback", () => {
  deepStrictEqual(routeFor({ model: "glm-5.3", private_inference: true }, defaults), {
    model: "glm-5.3", headers: { [TRUST_MODE_HEADER]: "private" }, fallback: null, private: true,
  });
});

Deno.test("the header name is the one 0G documents", () => {
  deepStrictEqual(TRUST_MODE_HEADER, "X-0G-Provider-Trust-Mode");
});
