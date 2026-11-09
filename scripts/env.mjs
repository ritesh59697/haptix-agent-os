// Read a required setting from the environment. Keys and endpoints are never hardcoded
// in scripts; a missing one stops the script with a message saying what to set.
export function requireEnv(name, hint) {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing ${name}.${hint ? ` ${hint}` : ''}`);
    process.exit(2);
  }
  return v;
}
