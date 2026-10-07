// Public settings only. NEVER add service_role, sb_secret_ or a password.
window.DEADLINE_CONFIG = Object.freeze({
  supabaseUrl: "", // https://YOUR-PROJECT.supabase.co
  supabasePublishableKey: "", // sb_publishable_... or a legacy anon key
  turnstileSiteKey: "" // Optional PUBLIC key. Secret goes in Supabase Auth settings.
});
