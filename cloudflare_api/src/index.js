export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type",
        },
      });
    }

    try {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405 });
      }

      const body = await request.json();
      const { query, params } = body;

      if (!query) {
        return new Response(JSON.stringify({ error: "Missing query" }), { status: 400 });
      }

      const stmt = env.DB.prepare(query);
      
      let result;
      if (params && params.length > 0) {
        result = await stmt.bind(...params).all();
      } else {
        result = await stmt.all();
      }

      return new Response(JSON.stringify(result.results ?? []), {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      });
    } catch (e) {
      return new Response(JSON.stringify({ error: e.message }), {
        status: 500,
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      });
    }
  },
};
