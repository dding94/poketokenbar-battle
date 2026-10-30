declare namespace Cloudflare {
  interface Env {
    LEAGUE: DurableObjectNamespace<import("./league").League>;
    /** Group creation is disabled when this is missing or shorter than 32 characters. */
    OPERATOR_SECRET?: string;
    /** HMAC key for human-entered codes and client IPs. */
    CODE_PEPPER?: string;
  }
  interface GlobalProps {
    mainModule: typeof import("./index");
    durableNamespaces: "League";
  }
}

interface Env extends Cloudflare.Env {}
