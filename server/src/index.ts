export { League } from "./league";

export default {
  async fetch(): Promise<Response> {
    return new Response(JSON.stringify({ error: { code: "not_implemented" } }), {
      status: 501,
      headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
    });
  },
} satisfies ExportedHandler<Env>;
