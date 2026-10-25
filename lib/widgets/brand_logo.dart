import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/mcp_oauth.dart';
import '../theme.dart';
import 'pill_kit.dart';

/// Real app logos for the Apps screen (plan 4 "Logos", plan 5.5).
/// Single-colour marks come from Simple Icons (CC0, assets/logos/<id>.svg) and are
/// drawn in the brand's own colour; apps Simple Icons doesn't carry use their own
/// icon (assets/logos/<id>.png or a full-colour .svg). Anything else falls back to
/// the serif letter tile, so a new app never shows a broken image.
class BrandLogo extends StatelessWidget {
  const BrandLogo(this.id, this.name, {super.key, this.size = 40, this.on = false});

  /// App id as used by the catalog (ConnDef.id / McpPreset.id).
  final String id;
  final String name;
  final double size;

  /// Connected: a small check badge on the tile's corner.
  final bool on;

  /// Brand colours for the single-colour marks.
  static const tint = <String, int>{
    'airtable': 0xFF18BFFF,
    'asana': 0xFFF06A6A,
    'atlassian': 0xFF0052CC,
    'basecamp': 0xFF1D2D35,
    'brave': 0xFFFB542B,
    'brevo': 0xFF0B996E,
    'buffer': 0xFF231F20,
    'buildkite': 0xFF14CC80,
    'calcom': 0xFF292929,
    'calendly': 0xFF006BFF,
    'clerk': 0xFF6C47FF,
    'clickup': 0xFF7B68EE,
    'cloudflare': 0xFFF38020,
    'coda': 0xFFF46A54,
    'confluence': 0xFF172B4D,
    'discord': 0xFF5865F2,
    'dropbox': 0xFF0061FF,
    'elevenlabs': 0xFF000000,
    'figma': 0xFFF24E1E,
    'framer': 0xFF0055FF,
    'gitbook': 0xFFBBDDE5,
    'github': 0xFF181717,
    'gitlab': 0xFFFC6D26,
    'gmail': 0xFFEA4335,
    'godaddy': 0xFF1BDBDB,
    'grafana': 0xFFF46800,
    'greenhouse': 0xFF24A47F,
    'homeassistant': 0xFF18BCF2,
    'hubspot': 0xFFFF7A59,
    'huggingface': 0xFFFFD21E,
    'icloud': 0xFF3693F3,
    'ilovepdf': 0xFFE5322D,
    'instacart': 0xFF43B02A,
    'intercom': 0xFF6AFDEF,
    'jira': 0xFF0052CC,
    'linear': 0xFF5E6AD2,
    'lottiefiles': 0xFF00DDB3,
    'mailchimp': 0xFFFFE01B,
    'make': 0xFF6D00CC,
    'mapbox': 0xFF000000,
    'meetup': 0xFFED1C40,
    'mintlify': 0xFF18E299,
    'miro': 0xFF050038,
    'mixpanel': 0xFF7856FF,
    'neon': 0xFF34D59A,
    'netlify': 0xFF00C7B7,
    'newrelic': 0xFF1CE783,
    'notion': 0xFF000000,
    'paddle': 0xFFFDDD35,
    'paypal': 0xFF002991,
    'pexels': 0xFF05A081,
    'posthog': 0xFF000000,
    'postman': 0xFFFF6C37,
    'railway': 0xFF0B0D0E,
    'razorpay': 0xFF0C2451,
    'replicate': 0xFF000000,
    'resend': 0xFF000000,
    'retool': 0xFF3D3D3D,
    'sentry': 0xFF362D59,
    'shopify': 0xFF7AB55C,
    'square': 0xFF3E4348,
    'stripe': 0xFF635BFF,
    'supabase': 0xFF3FCF8E,
    'telegram': 0xFF26A5E4,
    'todoist': 0xFFE44332,
    'toggl': 0xFFFFDE91,
    'trello': 0xFF0052CC,
    'typeform': 0xFF262627,
    'unsplash': 0xFF000000,
    'vercel': 0xFF000000,
    'vimeo': 0xFF1AB7EA,
    'webflow': 0xFF146EF5,
    'whatsapp': 0xFF25D366,
    'wix': 0xFF0C6EFC,
    'woocommerce': 0xFF96588A,
    'wordpress': 0xFF21759B,
    'youtube': 0xFFFF0000,
    'zapier': 0xFFFF4F00,
    'zendesk': 0xFF03363D,
    'zoho': 0xFFE42527,
  };

  /// Apps drawn from their own picture.
  static const pictures = <String>{'alphavantage', 'amplitude', 'apify', 'apollo', 'attio', 'axiom', 'brightdata', 'canva', 'close', 'coingecko', 'consensus', 'context7', 'dataforseo', 'deepwiki', 'dice', 'exa', 'fireflies', 'folk', 'frameio', 'freshdesk', 'gitguardian', 'globalping', 'granola', 'honeycomb', 'hunter', 'invideo', 'jam', 'jina', 'jotform', 'kajabi', 'kiwi', 'klaviyo', 'krisp', 'lovable', 'mem', 'mercury', 'monday', 'mslearn', 'mux', 'newsapi', 'otter', 'parallel', 'pcloud', 'peek', 'pipedream', 'pipedrive', 'productboard', 'ramp', 'recurly', 'sendgrid', 'serper', 'shipstation', 'spline', 'supermemory', 'tavily', 'twilio', 'vanta', 'workable', 'yahoo', 'zenrows'};

  /// Full-colour vector marks (drawn as they are).
  static const colourMarks = <String>{'slack'};

  /// The catalog id for an app, from its id or its server address.
  static String idFor(String key, {String url = ''}) {
    final k = key.toLowerCase();
    if (has(k)) return k;
    // mcp.notion.com -> notion; search-mcp.parallel.ai -> parallel (whole labels only, so mem never matches supermemory).
    final labels = (Uri.tryParse(url)?.host.toLowerCase() ?? '').split('.');
    for (final l in labels.reversed) {
      for (final part in [l, ...l.split('-')]) {
        if (has(part)) return part;
      }
    }
    return k;
  }

  /// The logo for an app a bot uses: a key app by its id, a sign-in app by its server link.
  static String idForApp(String kind, String ref, String name) {
    if (kind != 'mcp') return idFor(ref);
    for (final pr in McpOAuth.presets) {
      if (pr.url == ref) return pr.id;
    }
    return idFor(name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''), url: ref);
  }

  static bool has(String id) => tint.containsKey(id) || pictures.contains(id) || colourMarks.contains(id);

  /// A brand colour too pale to read on the light tile is drawn in ink instead.
  static Color readable(Color c) => c.computeLuminance() > 0.72 ? const Color(0xFF17150F) : c;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final key = id.toLowerCase();
    if (!has(key)) return _badge(context, Monogram(name, size: size, accent: on));
    final mark = size * 0.56;
    final Widget art;
    if (tint.containsKey(key)) {
      art = SvgPicture.asset('assets/logos/$key.svg',
          width: mark, height: mark, colorFilter: ColorFilter.mode(readable(Color(tint[key]!)), BlendMode.srcIn));
    } else if (colourMarks.contains(key)) {
      art = SvgPicture.asset('assets/logos/$key.svg', width: mark, height: mark);
    } else {
      // Own icons are often full squares already: give them most of the tile, softly rounded.
      final pic = size * 0.7;
      art = ClipRRect(
        borderRadius: BorderRadius.circular(pic * 0.22),
        child: Image.asset('assets/logos/$key.png',
            width: pic,
            height: pic,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => Monogram(name, size: pic)),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _badge(
      context,
      Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // Logos are made for white: the tile stays white in both themes, like an app icon.
          color: dark ? const Color(0xFFF7F7F5) : Colors.white,
          borderRadius: BorderRadius.circular(size * 0.28),
          border: Border.all(color: dark ? Colors.transparent : p.border.withValues(alpha: 0.55), width: 0.6),
        ),
        child: art,
      ),
    );
  }

  Widget _badge(BuildContext context, Widget tile) {
    if (!on) return tile;
    final p = Palette.of(context);
    final d = size * 0.36;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        tile,
        Positioned(
          right: -d * 0.25,
          bottom: -d * 0.25,
          child: Container(
            width: d,
            height: d,
            decoration: BoxDecoration(color: p.text, shape: BoxShape.circle, border: Border.all(color: p.sheet, width: 1.6)),
            child: Icon(Icons.check_rounded, size: d * 0.66, color: p.bg),
          ),
        ),
      ]),
    );
  }
}

/// A tile for something on the phone itself (Calendar, Contacts...), drawn to match the logos.
class PhoneAppTile extends StatelessWidget {
  const PhoneAppTile(this.icon, {super.key, this.size = 40});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(size * 0.28)),
      child: Icon(icon, size: size * 0.5, color: p.text),
    );
  }
}
