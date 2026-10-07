// Public settings only. NEVER add service_role, sb_secret_ or a password.
window.DEADLINE_CONFIG = Object.freeze({
  supabaseUrl: "https://vsjozhwpetyxxwirqlmw.supabase.co", // https://YOUR-PROJECT.supabase.co
  supabasePublishableKey: "sb_publishable_LgeeGU45gEy_F5C_YC83QQ_CbCxX1mj", // sb_publishable_... or a legacy anon key
  turnstileSiteKey: "" // Optional PUBLIC key. Secret goes in Supabase Auth settings.
});
