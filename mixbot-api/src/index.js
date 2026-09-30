// MixBot menu API
//
// Routes:
//   GET  /menu         public; returns the current menu JSON
//   PUT  /menu         Bearer auth; validates, backs up, stores a new menu
//   GET  /menu/backup  Bearer auth; returns the previous menu version
//
// Storage: KV namespace MENU_KV, keys "menu" and "menu-backup".
// Each value carries { updatedAt } metadata used as the ETag / If-Match token.

export default {
    async fetch(request, env) {
        const path = new URL(request.url).pathname.replace(/\/+$/, "");

        if (path === "/menu" && request.method === "GET") {
            return getMenu(env);
        }
        if (path === "/menu" && request.method === "PUT") {
            return putMenu(request, env);
        }
        if (path === "/menu/backup" && request.method === "GET") {
            if (!(await authorized(request, env))) return unauthorized();
            return getKey(env, "menu-backup");
        }

        return json({ error: "Not found" }, 404);
    },
};

async function getMenu(env) {
    return getKey(env, "menu");
}

async function getKey(env, key) {
    const { value, metadata } = await env.MENU_KV.getWithMetadata(key);
    if (value === null) {
        return json({ error: `No ${key} stored yet` }, 404);
    }
    const updatedAt = metadata?.updatedAt ?? "unknown";
    return new Response(value, {
        headers: {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
            "ETag": `"${updatedAt}"`,
            "X-Updated-At": updatedAt,
        },
    });
}

async function putMenu(request, env) {
    if (!(await authorized(request, env))) return unauthorized();

    let menu;
    try {
        menu = JSON.parse(await request.text());
    } catch (error) {
        return json({ error: `Not valid JSON: ${error.message}` }, 422);
    }

    const problems = validateMenu(menu);
    if (problems.length > 0) {
        return json({ error: "Menu rejected", problems }, 422);
    }

    // Stale-write protection: a PUT must name the version it was based on.
    // First-ever PUT (empty store) is exempt so the store can be seeded.
    const existing = await env.MENU_KV.getWithMetadata("menu");
    if (existing.value !== null) {
        const current = existing.metadata?.updatedAt ?? "unknown";
        const ifMatch = (request.headers.get("If-Match") ?? "").replaceAll('"', "");
        if (ifMatch !== current) {
            return json(
                {
                    error: "Menu was changed by someone else. Refresh and retry.",
                    currentUpdatedAt: current,
                },
                409,
            );
        }
        await env.MENU_KV.put("menu-backup", existing.value, {
            metadata: existing.metadata,
        });
    }

    const updatedAt = new Date().toISOString();
    await env.MENU_KV.put("menu", JSON.stringify(menu, null, 4), {
        metadata: { updatedAt },
    });

    return json({ ok: true, updatedAt });
}

// Mirrors the app's DrinkMenu.resolvedDrinks() rules so a bad file can
// never be published. Returns every problem found, not just the first,
// so an editor can show them all at once.
function validateMenu(menu) {
    const problems = [];

    if (typeof menu !== "object" || menu === null || Array.isArray(menu)) {
        return ["Top level must be an object with version, stations and drinks"];
    }
    if (menu.version !== 2) {
        problems.push(`version must be 2 (got ${JSON.stringify(menu.version)})`);
    }

    const stationIds = new Set();
    if (!Array.isArray(menu.stations) || menu.stations.length === 0) {
        problems.push("stations must be a non-empty array");
    } else {
        for (const station of menu.stations) {
            if (!Number.isInteger(station?.id)) {
                problems.push(`Station id must be an integer (got ${JSON.stringify(station?.id)})`);
                continue;
            }
            if (stationIds.has(station.id)) {
                problems.push(`Duplicate station id ${station.id}`);
            }
            stationIds.add(station.id);
            if (typeof station.name !== "string" || station.name.trim() === "") {
                problems.push(`Station ${station.id} needs a non-empty name`);
            }
        }
    }

    if (!Array.isArray(menu.drinks) || menu.drinks.length === 0) {
        problems.push("drinks must be a non-empty array");
        return problems;
    }

    const drinkNames = new Set();
    for (const [index, drink] of menu.drinks.entries()) {
        const where = `Drink '${drink?.name ?? `#${index + 1}`}'`;

        if (typeof drink?.name !== "string" || drink.name.trim() === "") {
            problems.push(`Drink #${index + 1} needs a non-empty name`);
        } else if (drinkNames.has(drink.name)) {
            // Drink names are the app's stable identity for cards and sheets
            problems.push(`Duplicate drink name '${drink.name}'`);
        } else {
            drinkNames.add(drink.name);
        }

        if (typeof drink?.description !== "string") {
            problems.push(`${where}: description must be a string (use "" for none)`);
        }
        if (!Number.isInteger(drink?.totalQty) || drink.totalQty <= 0) {
            problems.push(`${where}: totalQty must be a positive integer (ml)`);
        }

        if (!Array.isArray(drink?.ingredients) || drink.ingredients.length === 0) {
            problems.push(`${where}: needs at least one ingredient`);
            continue;
        }

        let percentSum = 0;
        for (const ingredient of drink.ingredients) {
            if (!stationIds.has(ingredient?.stationId)) {
                problems.push(`${where}: references unknown station ${JSON.stringify(ingredient?.stationId)}`);
            }
            if (typeof ingredient?.percent !== "number" || ingredient.percent < 0 || ingredient.percent > 100) {
                problems.push(`${where}: percent must be a number between 0 and 100`);
            } else {
                percentSum += ingredient.percent;
            }
            if (ingredient?.label !== undefined && (typeof ingredient.label !== "string" || ingredient.label.trim() === "")) {
                problems.push(`${where}: label, when present, must be a non-empty string`);
            }
        }

        if (Math.abs(percentSum - 100) > 0.5) {
            problems.push(`${where}: percents sum to ${percentSum}, expected 100`);
        }
    }

    return problems;
}

async function authorized(request, env) {
    const header = request.headers.get("Authorization") ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : "";
    const secret = env.MENU_TOKEN;
    if (!secret || !token) return false;

    const encoder = new TextEncoder();
    const a = encoder.encode(token);
    const b = encoder.encode(secret);
    if (a.byteLength !== b.byteLength) return false;
    return crypto.subtle.timingSafeEqual(a, b);
}

function unauthorized() {
    return json({ error: "Missing or invalid bearer token" }, 401);
}

function json(body, status = 200) {
    return new Response(JSON.stringify(body, null, 2), {
        status,
        headers: { "Content-Type": "application/json" },
    });
}
