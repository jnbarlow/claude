// ─── Secret Retrieval Chain ────────────────────────────────────────
// Resolves the PostgreSQL connection string from a user-selected provider.
// Fixed secret name: "LTM-DB" across all providers — no per-user naming config needed.
// Final fallback: LTM_DB_URL environment variable for local dev / headless use.

const SECRET_NAME = "LTM-DB";

// ─── AWS Secrets Manager ──────────────────────────────────────────

async function tryAwsSecretsManager(name: string): Promise<string | null> {
  try {
    const { SecretsManagerClient, GetSecretValueCommand } = await import(
      "@aws-sdk/client-secrets-manager"
    );
    const client = new SecretsManagerClient({}); // Uses standard credential chain.
    const command = new GetSecretValueCommand({ SecretId: name });

    const response = await client.send(command);

    // AWS returns either SecretString or SecretBinary — we expect a string.
    if (response.SecretString) {
      console.log("[ltm-mcp] Resolved connection string from AWS Secrets Manager.");
      return response.SecretString;
    }

    console.error(
      "[ltm-mcp] AWS Secrets Manager returned secret but no SecretString field."
    );
    return null;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[ltm-mcp] AWS Secrets Manager lookup failed: ${msg}`);
    return null;
  }
}

// ─── 1Password Connect Server ──────────────────────────────────────

async function tryOnePasswordConnect(name: string): Promise<string | null> {
  try {
    const opModule = await import("@1password/connect");

    // OP_CONNECT_HOST + OP_CONNECT_TOKEN are the standard env vars for Connect Server.
    const serverUrl = process.env.OP_CONNECT_HOST || "http://localhost:8080";
    const token = process.env.OP_CONNECT_TOKEN;
    if (!token) {
      console.error("[ltm-mcp] 1Password Connect: OP_CONNECT_TOKEN not set.");
      return null;
    }

    // OnePasswordConnect is exported as alias for newConnectClient (factory fn).
    const client = (opModule.OnePasswordConnect as any)({ serverURL: serverUrl, token });

    // If a specific vault is configured, look there. Otherwise search all accessible vaults.
    const targetVaultId = process.env.OP_VAULT || "";
    let fullItem: any = null;

    if (targetVaultId) {
      try {
        fullItem = await client.getItemByTitle(targetVaultId, name);
      } catch {
        // Item not found in specified vault.
      }
    } else {
      const vaults = await client.listVaults();
      for (const vault of vaults) {
        try {
          fullItem = await client.getItemByTitle(vault.id, name);
          break;
        } catch {
          // Not in this vault — keep searching.
        }
      }
    }

    if (!fullItem || !fullItem.fields) {
      console.error(`[ltm-mcp] 1Password: No item titled "${name}" found.`);
      return null;
    }

    let connStr: string | null = null;

    // Search fields for one labeled "connection_string".
    for (const field of fullItem.fields) {
      if (field.label === "connection_string" && field.value) {
        connStr = field.value;
        break;
      }
    }

    // Fallback: try the first concealed-type field.
    if (!connStr) {
      for (const field of fullItem.fields) {
        if (field.type === "Concealed" && field.value) {
          connStr = field.value;
          break;
        }
      }
    }

    if (!connStr) {
      console.error(
        `[ltm-mcp] 1Password: Item "${name}" found but no connection_string field.`
      );
      return null;
    }

    console.log("[ltm-mcp] Resolved connection string from 1Password Connect.");
    return connStr;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[ltm-mcp] 1Password Connect lookup failed: ${msg}`);
    return null;
  }
}

// ─── System Keychain (keytar) ──────────────────────────────────────

async function tryKeytar(name: string): Promise<string | null> {
  const serviceName = "ltm-mcp";
  try {
    const keytar = await import("keytar");
    const connStr = await keytar.getPassword(serviceName, name);

    if (connStr) {
      console.log("[ltm-mcp] Resolved connection string from system keychain.");
      return connStr;
    }

    console.error(
      `[ltm-mcp] System keychain: No password found for service="${serviceName}", account="${name}".`
    );
    return null;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    // Native binding failures are common on headless Linux without libsecret.
    console.error(
      `[ltm-mcp] System keychain (keytar) unavailable: ${msg}. ` +
        "This is expected on headless Linux — use LTM_DB_URL env var or configure a different provider."
    );
    return null;
  }
}

// ─── Public API ────────────────────────────────────────────────────

/**
 * Resolve the PostgreSQL connection string from the configured provider.
 * @param provider - 'aws' | '1password' | 'keychain'. Defaults to 'keychain'.
 * @returns The connection string, or null if resolution failed (env var fallback attempted).
 */
export async function resolveConnectionString(
  provider?: string // 'aws' | '1password' | 'keychain' (default: keychain)
): Promise<string | null> {
  const chosenProvider = provider || "keychain";

  let result: string | null;
  switch (chosenProvider) {
    case "aws":
      result = await tryAwsSecretsManager(SECRET_NAME);
      break;
    case "1password":
      result = await tryOnePasswordConnect(SECRET_NAME);
      break;
    case "keychain":
    default:
      result = await tryKeytar(SECRET_NAME);
      break;
  }

  if (result) return result;

  // Final fallback for local dev / headless environments where keychain unavailable.
  const envFallback = process.env.LTM_DB_URL;
  if (envFallback) {
    console.log("[ltm-mcp] Using LTM_DB_URL from environment variable.");
    return envFallback;
  }

  console.error(
    `[ltm-mcp] Could not resolve connection string from ${chosenProvider}. ` +
      "Store your credentials in the configured provider or export LTM_DB_URL."
  );
  return null;
}
