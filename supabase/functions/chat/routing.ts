// Which model an agent's turn runs on, and on which 0G trust tier.
//
// A private agent sends the trust header, so the router only uses TeeML providers (sealed
// inference inside a TEE). If none is available the router answers 503: it never drops to a
// lower tier, and neither do we, so a private agent has no fallback model.

export const TRUST_MODE_HEADER = "X-0G-Provider-Trust-Mode";

export type Route = {
  model: string;
  headers: Record<string, string>;
  /** Tried if `model` fails. Always null for a private agent. */
  fallback: string | null;
  private: boolean;
};

export function routeFor(
  agent: { model: string | null; private_inference: boolean },
  defaults: { model: string; privateModel: string },
): Route {
  const wanted = agent.model && agent.model !== defaults.model ? agent.model : null;
  if (agent.private_inference) {
    return { model: wanted ?? defaults.privateModel, headers: { [TRUST_MODE_HEADER]: "private" }, fallback: null, private: true };
  }
  return { model: wanted ?? defaults.model, headers: {}, fallback: wanted ? defaults.model : null, private: false };
}
