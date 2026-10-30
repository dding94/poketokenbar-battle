// Attempt limits count failures per client "bucket": an IPv4 address as is, or an IPv6 /64
// (one end site usually holds a whole /64, so per-address counting would be trivial to dodge).
// IPv4-mapped IPv6 (::ffff:a.b.c.d) counts as the IPv4 address. Anything unparseable is its
// own bucket; Cloudflare always sends a canonical CF-Connecting-IP, so that is only a fallback.

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const HEXTET = /^[0-9a-f]{1,4}$/i;

function ipv4Octets(text: string): number[] | null {
  const match = IPV4.exec(text);
  if (!match) return null;
  const octets = match.slice(1).map(Number);
  return octets.every((o) => o <= 255) ? octets : null;
}

function hextets(groups: string[], allowIpv4Tail: boolean): number[] | null {
  const out: number[] = [];
  for (const [index, group] of groups.entries()) {
    if (allowIpv4Tail && index === groups.length - 1 && group.includes(".")) {
      const octets = ipv4Octets(group);
      if (!octets) return null;
      out.push((octets[0]! << 8) | octets[1]!, (octets[2]! << 8) | octets[3]!);
    } else if (HEXTET.test(group)) {
      out.push(parseInt(group, 16));
    } else {
      return null;
    }
  }
  return out;
}

/** The eight 16-bit groups of an IPv6 address, or null. A zone id (`%eth0`) is ignored. */
function ipv6Groups(text: string): number[] | null {
  const address = text.split("%")[0]!;
  const halves = address.split("::");
  if (halves.length > 2) return null;
  const split = (part: string) => (part === "" ? [] : part.split(":"));
  if (halves.length === 1) {
    const all = hextets(split(address), true);
    return all && all.length === 8 ? all : null;
  }
  const head = hextets(split(halves[0]!), false);
  const tail = hextets(split(halves[1]!), true);
  if (!head || !tail || head.length + tail.length > 7) return null;
  return [...head, ...Array<number>(8 - head.length - tail.length).fill(0), ...tail];
}

export function attemptBucket(ip: string): string {
  if (ipv4Octets(ip)) return ip;
  if (!ip.includes(":")) return ip;
  const groups = ipv6Groups(ip);
  if (!groups) return ip;
  if (groups.slice(0, 5).every((g) => g === 0) && groups[5] === 0xffff) {
    return [groups[6]! >> 8, groups[6]! & 0xff, groups[7]! >> 8, groups[7]! & 0xff].join(".");
  }
  return `${groups
    .slice(0, 4)
    .map((g) => g.toString(16))
    .join(":")}::/64`;
}
