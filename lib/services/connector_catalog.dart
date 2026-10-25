import 'dart:async';
import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';
import 'package:http/http.dart' as http;

/// One field the user fills to connect a service (a key, a token, a site address).
class ConnField {
  final String key;
  final String label;
  final bool secret;
  final String hint;
  const ConnField(this.key, this.label, {this.secret = false, this.hint = ''});
}

/// A service SubMac can use with the user's own key or account: no app
/// registration, no SubMac servers in between.
class ConnDef {
  final String id;
  final String name;
  final String category;
  final String blurb;
  final List<ConnField> fields;

  /// Base URL; may contain {field} placeholders.
  final String base;

  /// Headers; values may contain {field} placeholders.
  final Map<String, String> headers;

  /// Query parameters added to every call.
  final Map<String, String> query;

  /// Basic auth as [user, password] templates (a leading "=" means a literal).
  final List<String>? basic;

  /// Send bodies as form fields instead of JSON (Stripe, Twilio).
  final bool form;
  final String helpUrl;
  final String help;
  final String examples;

  /// Request used by the Test button: [method, path, optional JSON body].
  final List<dynamic> test;

  /// 'api' (HTTP), 'email' (IMAP/SMTP), 'search' (feeds the web_search tool).
  final String kind;

  const ConnDef({
    required this.id,
    required this.name,
    required this.category,
    required this.blurb,
    required this.fields,
    this.base = '',
    this.headers = const {},
    this.query = const {},
    this.basic,
    this.form = false,
    required this.helpUrl,
    required this.help,
    this.examples = '',
    this.test = const ['GET', '/'],
    this.kind = 'api',
  });
}

const _token = [ConnField('token', 'Token', secret: true)];
const _key = [ConnField('key', 'API key', secret: true)];

class ConnectorCatalog {
  static const categories = [
    'Email',
    'Work and tasks',
    'Business and money',
    'Messaging',
    'Websites and code',
    'Search and media',
    'Home',
  ];

  static const List<ConnDef> all = [
    // ---------------- Email ----------------
    ConnDef(
      id: 'gmail', name: 'Gmail', category: 'Email', kind: 'email',
      blurb: 'Read, search and send email',
      fields: [ConnField('email', 'Gmail address'), ConnField('password', 'App password', secret: true, hint: '16 letters')],
      helpUrl: 'https://myaccount.google.com/apppasswords',
      help: 'Turn on 2-Step Verification, then create an "App password" for SubMac and paste it here.',
    ),
    ConnDef(
      id: 'yahoo', name: 'Yahoo Mail', category: 'Email', kind: 'email',
      blurb: 'Read, search and send email',
      fields: [ConnField('email', 'Yahoo address'), ConnField('password', 'App password', secret: true)],
      helpUrl: 'https://login.yahoo.com/account/security',
      help: 'In Account security, choose "Generate app password" and paste it here.',
    ),
    ConnDef(
      id: 'icloud', name: 'iCloud Mail', category: 'Email', kind: 'email',
      blurb: 'Read, search and send email',
      fields: [ConnField('email', 'iCloud address'), ConnField('password', 'App-specific password', secret: true)],
      helpUrl: 'https://account.apple.com/account/manage',
      help: 'In Sign-In and Security, create an app-specific password and paste it here.',
    ),
    ConnDef(
      id: 'zoho', name: 'Zoho Mail', category: 'Email', kind: 'email',
      blurb: 'Read, search and send email',
      fields: [ConnField('email', 'Zoho address'), ConnField('password', 'App password', secret: true)],
      helpUrl: 'https://accounts.zoho.com/home#security/app_password',
      help: 'Create an app password in Zoho security settings and turn on IMAP in Zoho Mail settings.',
    ),
    ConnDef(
      id: 'mail', name: 'Other email', category: 'Email', kind: 'email',
      blurb: 'Any email with IMAP and SMTP',
      fields: [
        ConnField('email', 'Email address'),
        ConnField('password', 'Password or app password', secret: true),
        ConnField('imap', 'Incoming server', hint: 'imap.example.com'),
        ConnField('smtp', 'Outgoing server', hint: 'smtp.example.com'),
      ],
      helpUrl: 'https://support.google.com/mail/answer/7126229',
      help: 'Your email provider lists its IMAP and SMTP servers in its help pages.',
    ),

    // ---------------- Work and tasks ----------------
    ConnDef(
      id: 'notion', name: 'Notion', category: 'Work and tasks', blurb: 'Pages, notes and databases',
      fields: _token, base: 'https://api.notion.com/v1',
      headers: {'Authorization': 'Bearer {token}', 'Notion-Version': '2022-06-28'},
      helpUrl: 'https://www.notion.so/profile/integrations',
      help: 'Create an internal integration, copy its secret, then share the pages you want with it.',
      examples: 'POST /search {"query":"..."}; GET /blocks/{id}/children; POST /pages; PATCH /blocks/{id}/children',
      test: ['GET', '/users/me'],
    ),
    ConnDef(
      id: 'airtable', name: 'Airtable', category: 'Work and tasks', blurb: 'Bases and records',
      fields: _token, base: 'https://api.airtable.com/v0', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://airtable.com/create/tokens', help: 'Create a personal access token with the bases you want.',
      examples: 'GET /meta/bases; GET /{baseId}/{table}?maxRecords=20; POST /{baseId}/{table} {"records":[{"fields":{}}]}',
      test: ['GET', '/meta/bases'],
    ),
    ConnDef(
      id: 'todoist', name: 'Todoist', category: 'Work and tasks', blurb: 'Tasks and projects',
      fields: _token, base: 'https://api.todoist.com/rest/v2', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://app.todoist.com/app/settings/integrations/developer', help: 'Copy your API token from Integrations > Developer.',
      examples: 'GET /tasks; POST /tasks {"content":"...","due_string":"tomorrow 9am"}; POST /tasks/{id}/close',
      test: ['GET', '/projects'],
    ),
    ConnDef(
      id: 'trello', name: 'Trello', category: 'Work and tasks', blurb: 'Boards and cards',
      fields: [ConnField('key', 'API key'), ConnField('token', 'Token', secret: true)],
      base: 'https://api.trello.com/1', query: {'key': '{key}', 'token': '{token}'},
      helpUrl: 'https://trello.com/power-ups/admin', help: 'Create a Power-Up to get an API key, then press "Token" next to it.',
      examples: 'GET /members/me/boards; GET /boards/{id}/lists; POST /cards {"idList":"...","name":"..."}',
      test: ['GET', '/members/me'],
    ),
    ConnDef(
      id: 'asana', name: 'Asana', category: 'Work and tasks', blurb: 'Tasks and projects',
      fields: _token, base: 'https://app.asana.com/api/1.0', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://app.asana.com/0/my-apps', help: 'Create a personal access token.',
      examples: 'GET /workspaces; GET /tasks?assignee=me&workspace={id}; POST /tasks {"data":{...}}',
      test: ['GET', '/users/me'],
    ),
    ConnDef(
      id: 'clickup', name: 'ClickUp', category: 'Work and tasks', blurb: 'Tasks, lists and docs',
      fields: _token, base: 'https://api.clickup.com/api/v2', headers: {'Authorization': '{token}'},
      helpUrl: 'https://app.clickup.com/settings/apps', help: 'Generate a personal API token under Apps.',
      examples: 'GET /team; GET /list/{id}/task; POST /list/{id}/task {"name":"..."}',
      test: ['GET', '/user'],
    ),
    ConnDef(
      id: 'linear', name: 'Linear', category: 'Work and tasks', blurb: 'Issues and projects',
      fields: _token, base: 'https://api.linear.app', headers: {'Authorization': '{token}'},
      helpUrl: 'https://linear.app/settings/account/security', help: 'Create a personal API key.',
      examples: 'POST /graphql {"query":"{ issues(first:10){ nodes{ title state{name} } } }"}',
      test: ['POST', '/graphql', {'query': '{ viewer { name } }'}],
    ),
    ConnDef(
      id: 'jira', name: 'Jira', category: 'Work and tasks', blurb: 'Issues and boards',
      fields: [ConnField('site', 'Site', hint: 'yourteam.atlassian.net'), ConnField('email', 'Email'), ConnField('token', 'API token', secret: true)],
      base: 'https://{site}/rest/api/3', basic: ['{email}', '{token}'],
      helpUrl: 'https://id.atlassian.com/manage-profile/security/api-tokens', help: 'Create an API token for your Atlassian account.',
      examples: 'GET /search/jql?jql=assignee=currentUser()&maxResults=20; POST /issue',
      test: ['GET', '/myself'],
    ),
    ConnDef(
      id: 'confluence', name: 'Confluence', category: 'Work and tasks', blurb: 'Team pages',
      fields: [ConnField('site', 'Site', hint: 'yourteam.atlassian.net'), ConnField('email', 'Email'), ConnField('token', 'API token', secret: true)],
      base: 'https://{site}/wiki/api/v2', basic: ['{email}', '{token}'],
      helpUrl: 'https://id.atlassian.com/manage-profile/security/api-tokens', help: 'Create an API token for your Atlassian account.',
      examples: 'GET /spaces; GET /pages?title=...; GET /pages/{id}?body-format=storage',
      test: ['GET', '/spaces?limit=1'],
    ),
    ConnDef(
      id: 'monday', name: 'monday.com', category: 'Work and tasks', blurb: 'Boards and items',
      fields: _token, base: 'https://api.monday.com/v2', headers: {'Authorization': '{token}', 'API-Version': '2024-10'},
      helpUrl: 'https://auth.monday.com/admin/integrations/api', help: 'Copy your personal API token from the Developer section.',
      examples: 'POST / {"query":"{ boards(limit:10){ id name } }"}',
      test: ['POST', '', {'query': '{ me { name } }'}],
    ),
    ConnDef(
      id: 'coda', name: 'Coda', category: 'Work and tasks', blurb: 'Docs and tables',
      fields: _token, base: 'https://coda.io/apis/v1', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://coda.io/account', help: 'Generate an API token in Account settings.',
      examples: 'GET /docs; GET /docs/{id}/tables; GET /docs/{id}/tables/{t}/rows',
      test: ['GET', '/whoami'],
    ),
    ConnDef(
      id: 'calendly', name: 'Calendly', category: 'Work and tasks', blurb: 'Meetings and bookings',
      fields: _token, base: 'https://api.calendly.com', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://calendly.com/integrations/api_webhooks', help: 'Generate a personal access token.',
      examples: 'GET /users/me; GET /scheduled_events?user={uri}&status=active',
      test: ['GET', '/users/me'],
    ),
    ConnDef(
      id: 'calcom', name: 'Cal.com', category: 'Work and tasks', blurb: 'Meetings and bookings',
      fields: _key, base: 'https://api.cal.com/v2', headers: {'Authorization': 'Bearer {key}', 'cal-api-version': '2024-08-13'},
      helpUrl: 'https://app.cal.com/settings/developer/api-keys', help: 'Create an API key in Developer settings.',
      examples: 'GET /bookings?status=upcoming; GET /event-types',
      test: ['GET', '/me'],
    ),
    ConnDef(
      id: 'typeform', name: 'Typeform', category: 'Work and tasks', blurb: 'Forms and answers',
      fields: _token, base: 'https://api.typeform.com', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://admin.typeform.com/user/tokens', help: 'Create a personal token.',
      examples: 'GET /forms; GET /forms/{id}/responses?page_size=20',
      test: ['GET', '/me'],
    ),
    ConnDef(
      id: 'toggl', name: 'Toggl Track', category: 'Work and tasks', blurb: 'Time tracking',
      fields: _token, base: 'https://api.track.toggl.com/api/v9', basic: ['{token}', '=api_token'],
      helpUrl: 'https://track.toggl.com/profile', help: 'Copy the API token at the bottom of your profile.',
      examples: 'GET /me/time_entries; GET /me/time_entries/current',
      test: ['GET', '/me'],
    ),

    // ---------------- Business and money ----------------
    ConnDef(
      id: 'shopify', name: 'Shopify', category: 'Business and money', blurb: 'Orders, products, customers',
      fields: [ConnField('store', 'Store name', hint: 'mystore (from mystore.myshopify.com)'), ConnField('token', 'Admin API token', secret: true)],
      base: 'https://{store}.myshopify.com/admin/api/2024-10', headers: {'X-Shopify-Access-Token': '{token}'},
      helpUrl: 'https://help.shopify.com/en/manual/apps/app-types/custom-apps', help: 'In Settings > Apps, develop an app for your store and install it to get an Admin API token.',
      examples: 'GET /orders.json?status=any&limit=20; GET /products.json; GET /customers.json',
      test: ['GET', '/shop.json'],
    ),
    ConnDef(
      id: 'woocommerce', name: 'WooCommerce', category: 'Business and money', blurb: 'Store orders and products',
      fields: [ConnField('site', 'Site', hint: 'mystore.com'), ConnField('ck', 'Consumer key'), ConnField('cs', 'Consumer secret', secret: true)],
      base: 'https://{site}/wp-json/wc/v3', basic: ['{ck}', '{cs}'],
      helpUrl: 'https://woocommerce.com/document/woocommerce-rest-api/', help: 'WooCommerce > Settings > Advanced > REST API > Add key.',
      examples: 'GET /orders?per_page=20; GET /products; PUT /products/{id}',
      test: ['GET', '/products?per_page=1'],
    ),
    ConnDef(
      id: 'stripe', name: 'Stripe', category: 'Business and money', blurb: 'Payments, invoices, customers',
      fields: [ConnField('key', 'Secret or restricted key', secret: true)], base: 'https://api.stripe.com/v1',
      headers: {'Authorization': 'Bearer {key}'}, form: true,
      helpUrl: 'https://dashboard.stripe.com/apikeys', help: 'A restricted key with read access is safest.',
      examples: 'GET /balance; GET /charges?limit=10; GET /invoices?limit=10; POST /payment_links',
      test: ['GET', '/balance'],
    ),
    ConnDef(
      id: 'hubspot', name: 'HubSpot', category: 'Business and money', blurb: 'Contacts, deals, CRM',
      fields: _token, base: 'https://api.hubapi.com', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://app.hubspot.com/private-apps', help: 'Create a private app and copy its access token.',
      examples: 'GET /crm/v3/objects/contacts?limit=20; POST /crm/v3/objects/contacts/search; GET /crm/v3/objects/deals',
      test: ['GET', '/crm/v3/objects/contacts?limit=1'],
    ),
    ConnDef(
      id: 'pipedrive', name: 'Pipedrive', category: 'Business and money', blurb: 'Deals and contacts',
      fields: _token, base: 'https://api.pipedrive.com/v1', query: {'api_token': '{token}'},
      helpUrl: 'https://app.pipedrive.com/settings/api', help: 'Copy your personal API token.',
      examples: 'GET /deals?limit=20; GET /persons/search?term=...; POST /activities',
      test: ['GET', '/users/me'],
    ),
    ConnDef(
      id: 'mailchimp', name: 'Mailchimp', category: 'Business and money', blurb: 'Audiences and campaigns',
      fields: [ConnField('key', 'API key', secret: true, hint: 'ends with -us21 etc.'), ConnField('dc', 'Server', hint: 'us21 (end of the key)')],
      base: 'https://{dc}.api.mailchimp.com/3.0', basic: ['=submac', '{key}'],
      helpUrl: 'https://us1.admin.mailchimp.com/account/api/', help: 'Create an API key. The part after the dash is your server.',
      examples: 'GET /lists; GET /campaigns?count=10; POST /lists/{id}/members',
      test: ['GET', '/ping'],
    ),
    ConnDef(
      id: 'brevo', name: 'Brevo', category: 'Business and money', blurb: 'Email marketing and SMS',
      fields: _key, base: 'https://api.brevo.com/v3', headers: {'api-key': '{key}'},
      helpUrl: 'https://app.brevo.com/settings/keys/api', help: 'Create an API key.',
      examples: 'GET /contacts?limit=20; POST /smtp/email',
      test: ['GET', '/account'],
    ),
    ConnDef(
      id: 'sendgrid', name: 'SendGrid', category: 'Business and money', blurb: 'Send email',
      fields: _key, base: 'https://api.sendgrid.com/v3', headers: {'Authorization': 'Bearer {key}'},
      helpUrl: 'https://app.sendgrid.com/settings/api_keys', help: 'Create an API key.',
      examples: 'POST /mail/send',
      test: ['GET', '/user/profile'],
    ),
    ConnDef(
      id: 'resend', name: 'Resend', category: 'Business and money', blurb: 'Send email',
      fields: _key, base: 'https://api.resend.com', headers: {'Authorization': 'Bearer {key}'},
      helpUrl: 'https://resend.com/api-keys', help: 'Create an API key.',
      examples: 'POST /emails {"from":"...","to":["..."],"subject":"...","html":"..."}',
      test: ['GET', '/domains'],
    ),
    ConnDef(
      id: 'zendesk', name: 'Zendesk', category: 'Business and money', blurb: 'Support tickets',
      fields: [ConnField('sub', 'Subdomain', hint: 'mycompany'), ConnField('email', 'Email'), ConnField('token', 'API token', secret: true)],
      base: 'https://{sub}.zendesk.com/api/v2', basic: ['{email}/token', '{token}'],
      helpUrl: 'https://support.zendesk.com/hc/en-us/articles/4408889192858', help: 'Admin Center > Apps and integrations > Zendesk API > add token.',
      examples: 'GET /tickets.json?sort_by=created_at&sort_order=desc; PUT /tickets/{id}.json',
      test: ['GET', '/users/me.json'],
    ),
    ConnDef(
      id: 'freshdesk', name: 'Freshdesk', category: 'Business and money', blurb: 'Support tickets',
      fields: [ConnField('domain', 'Domain', hint: 'mycompany'), ConnField('key', 'API key', secret: true)],
      base: 'https://{domain}.freshdesk.com/api/v2', basic: ['{key}', '=X'],
      helpUrl: 'https://support.freshdesk.com/support/solutions/articles/215517', help: 'Profile settings > Your API key.',
      examples: 'GET /tickets?per_page=20; POST /tickets/{id}/reply',
      test: ['GET', '/agents/me'],
    ),

    // ---------------- Messaging ----------------
    ConnDef(
      id: 'telegram', name: 'Telegram bot', category: 'Messaging', blurb: 'Send and read bot messages',
      fields: [ConnField('token', 'Bot token', secret: true, hint: 'from @BotFather')], base: 'https://api.telegram.org/bot{token}',
      helpUrl: 'https://t.me/BotFather', help: 'Message @BotFather, send /newbot and paste the token it gives you.',
      examples: 'GET /getUpdates; POST /sendMessage {"chat_id":123,"text":"..."}',
      test: ['GET', '/getMe'],
    ),
    ConnDef(
      id: 'slack', name: 'Slack', category: 'Messaging', blurb: 'Channels and messages',
      fields: [ConnField('token', 'Bot or user token', secret: true, hint: 'xoxb-... or xoxp-...')],
      base: 'https://slack.com/api', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://api.slack.com/apps', help: 'Create an app for your workspace, add scopes, install it and copy the token.',
      examples: 'GET /conversations.list; GET /conversations.history?channel=C..; POST /chat.postMessage {"channel":"C..","text":"..."}',
      test: ['GET', '/auth.test'],
    ),
    ConnDef(
      id: 'discord', name: 'Discord bot', category: 'Messaging', blurb: 'Servers and channels',
      fields: [ConnField('token', 'Bot token', secret: true)], base: 'https://discord.com/api/v10', headers: {'Authorization': 'Bot {token}'},
      helpUrl: 'https://discord.com/developers/applications', help: 'Create an application, add a bot, copy its token and invite it to your server.',
      examples: 'GET /users/@me/guilds; GET /channels/{id}/messages?limit=20; POST /channels/{id}/messages {"content":"..."}',
      test: ['GET', '/users/@me'],
    ),
    ConnDef(
      id: 'whatsapp', name: 'WhatsApp Business', category: 'Messaging', blurb: 'Send WhatsApp messages (Cloud API)',
      fields: [ConnField('token', 'Access token', secret: true), ConnField('phone', 'Phone number ID')],
      base: 'https://graph.facebook.com/v21.0', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://developers.facebook.com/docs/whatsapp/cloud-api/get-started', help: 'For WhatsApp Business accounts. Copy the access token and phone number ID from WhatsApp > API Setup.',
      examples: 'POST /{phone}/messages {"messaging_product":"whatsapp","to":"2526...","type":"text","text":{"body":"..."}}',
      test: ['GET', '/{phone}'],
    ),
    ConnDef(
      id: 'twilio', name: 'Twilio', category: 'Messaging', blurb: 'SMS and calls',
      fields: [ConnField('sid', 'Account SID'), ConnField('token', 'Auth token', secret: true)],
      base: 'https://api.twilio.com/2010-04-01/Accounts/{sid}', basic: ['{sid}', '{token}'], form: true,
      helpUrl: 'https://console.twilio.com/', help: 'Copy the Account SID and Auth token from the console home.',
      examples: 'POST /Messages.json {"To":"+252...","From":"+1...","Body":"..."}; GET /Messages.json?PageSize=20',
      test: ['GET', '.json'],
    ),

    // ---------------- Websites and code ----------------
    ConnDef(
      id: 'wordpress', name: 'WordPress', category: 'Websites and code', blurb: 'Posts and pages on your site',
      fields: [ConnField('site', 'Site', hint: 'myblog.com'), ConnField('user', 'Username'), ConnField('password', 'Application password', secret: true)],
      base: 'https://{site}/wp-json/wp/v2', basic: ['{user}', '{password}'],
      helpUrl: 'https://wordpress.org/documentation/article/application-passwords/', help: 'Users > Profile > Application passwords > Add new.',
      examples: 'GET /posts?per_page=10; POST /posts {"title":"...","content":"...","status":"draft"}',
      test: ['GET', '/users/me'],
    ),
    ConnDef(
      id: 'github', name: 'GitHub', category: 'Websites and code', blurb: 'Repos, issues, pull requests',
      fields: _token, base: 'https://api.github.com',
      headers: {'Authorization': 'Bearer {token}', 'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'},
      helpUrl: 'https://github.com/settings/tokens', help: 'Create a token (classic) with the repo and workflow scopes, so SubMac can save your code, build your app and host your site.',
      examples: 'GET /user/repos?per_page=20; GET /repos/{o}/{r}/issues; POST /repos/{o}/{r}/issues {"title":"..."}',
      test: ['GET', '/user'],
    ),
    ConnDef(
      id: 'gitlab', name: 'GitLab', category: 'Websites and code', blurb: 'Projects and issues',
      fields: _token, base: 'https://gitlab.com/api/v4', headers: {'PRIVATE-TOKEN': '{token}'},
      helpUrl: 'https://gitlab.com/-/user_settings/personal_access_tokens', help: 'Create a personal access token.',
      examples: 'GET /projects?membership=true; GET /projects/{id}/issues',
      test: ['GET', '/user'],
    ),
    ConnDef(
      id: 'vercel', name: 'Vercel', category: 'Websites and code', blurb: 'Sites and deployments',
      fields: _token, base: 'https://api.vercel.com', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://vercel.com/account/tokens', help: 'Create a token.',
      examples: 'GET /v9/projects; GET /v6/deployments?limit=10',
      test: ['GET', '/v2/user'],
    ),
    ConnDef(
      id: 'netlify', name: 'Netlify', category: 'Websites and code', blurb: 'Sites and deploys',
      fields: _token, base: 'https://api.netlify.com/api/v1', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://app.netlify.com/user/applications#personal-access-tokens', help: 'Create a personal access token.',
      examples: 'GET /sites; GET /sites/{id}/deploys',
      test: ['GET', '/user'],
    ),
    ConnDef(
      id: 'cloudflare', name: 'Cloudflare', category: 'Websites and code', blurb: 'Domains, DNS, pages',
      fields: _token, base: 'https://api.cloudflare.com/client/v4', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://dash.cloudflare.com/profile/api-tokens', help: 'Create an API token with the permissions you need.',
      examples: 'GET /zones; GET /zones/{id}/dns_records',
      test: ['GET', '/user/tokens/verify'],
    ),
    ConnDef(
      id: 'supabase', name: 'Supabase', category: 'Websites and code', blurb: 'Projects and databases',
      fields: _token, base: 'https://api.supabase.com/v1', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://supabase.com/dashboard/account/tokens', help: 'Create an access token.',
      examples: 'GET /projects; POST /projects/{ref}/database/query {"query":"select 1"}',
      test: ['GET', '/projects'],
    ),
    ConnDef(
      id: 'figma', name: 'Figma', category: 'Websites and code', blurb: 'Design files and comments',
      fields: _token, base: 'https://api.figma.com/v1', headers: {'X-Figma-Token': '{token}'},
      helpUrl: 'https://www.figma.com/settings', help: 'Security > Personal access tokens > Generate.',
      examples: 'GET /files/{key}; GET /files/{key}/comments',
      test: ['GET', '/me'],
    ),

    // ---------------- Search and media ----------------
    ConnDef(
      id: 'brave', name: 'Brave Search', category: 'Search and media', kind: 'search', blurb: 'Better web search',
      fields: _key, helpUrl: 'https://api-dashboard.search.brave.com/app/keys', help: 'The free plan is enough.',
    ),
    ConnDef(
      id: 'tavily', name: 'Tavily', category: 'Search and media', kind: 'search', blurb: 'Research-grade search',
      fields: _key, helpUrl: 'https://app.tavily.com/home', help: 'Free monthly credits.',
    ),
    ConnDef(
      id: 'serper', name: 'Serper (Google results)', category: 'Search and media', blurb: 'Google search, news, images, places',
      fields: _key, base: 'https://google.serper.dev', headers: {'X-API-KEY': '{key}'},
      helpUrl: 'https://serper.dev/api-key', help: 'Free starting credits.',
      examples: 'POST /search {"q":"..."}; POST /news {"q":"..."}; POST /images {"q":"..."}; POST /places {"q":"..."}',
      test: ['POST', '/search', {'q': 'Mogadishu'}],
    ),
    ConnDef(
      id: 'youtube', name: 'YouTube', category: 'Search and media', blurb: 'Search videos and channels',
      fields: _key, base: 'https://www.googleapis.com/youtube/v3', query: {'key': '{key}'},
      helpUrl: 'https://console.cloud.google.com/apis/library/youtube.googleapis.com', help: 'Enable YouTube Data API v3 and create an API key.',
      examples: 'GET /search?part=snippet&q=...&maxResults=10; GET /videos?part=statistics&id=...',
      test: ['GET', '/search?part=snippet&q=news&maxResults=1'],
    ),
    ConnDef(
      id: 'pexels', name: 'Pexels', category: 'Search and media', blurb: 'Free photos and videos',
      fields: _key, base: 'https://api.pexels.com/v1', headers: {'Authorization': '{key}'},
      helpUrl: 'https://www.pexels.com/api/', help: 'Request a free API key.',
      examples: 'GET /search?query=...&per_page=10',
      test: ['GET', '/curated?per_page=1'],
    ),
    ConnDef(
      id: 'unsplash', name: 'Unsplash', category: 'Search and media', blurb: 'Free photos',
      fields: _key, base: 'https://api.unsplash.com', headers: {'Authorization': 'Client-ID {key}'},
      helpUrl: 'https://unsplash.com/oauth/applications', help: 'Create an app and copy its Access Key.',
      examples: 'GET /search/photos?query=...&per_page=10',
      test: ['GET', '/photos?per_page=1'],
    ),
    ConnDef(
      id: 'newsapi', name: 'NewsAPI', category: 'Search and media', blurb: 'Headlines from many sources',
      fields: _key, base: 'https://newsapi.org/v2', headers: {'X-Api-Key': '{key}'},
      helpUrl: 'https://newsapi.org/register', help: 'Free developer key.',
      examples: 'GET /top-headlines?country=us; GET /everything?q=...&sortBy=publishedAt',
      test: ['GET', '/top-headlines?country=us&pageSize=1'],
    ),
    ConnDef(
      id: 'elevenlabs', name: 'ElevenLabs', category: 'Search and media', blurb: 'Natural voices',
      fields: _key, base: 'https://api.elevenlabs.io/v1', headers: {'xi-api-key': '{key}'},
      helpUrl: 'https://elevenlabs.io/app/settings/api-keys', help: 'Create an API key.',
      examples: 'GET /voices',
      test: ['GET', '/user'],
    ),

    // ---------------- Home ----------------
    ConnDef(
      id: 'homeassistant', name: 'Home Assistant', category: 'Home', blurb: 'Lights, switches, sensors',
      fields: [ConnField('url', 'Address', hint: 'https://myhome.duckdns.org:8123'), ConnField('token', 'Long-lived token', secret: true)],
      base: '{url}/api', headers: {'Authorization': 'Bearer {token}'},
      helpUrl: 'https://www.home-assistant.io/docs/authentication/', help: 'Profile > Security > Long-lived access tokens > Create.',
      examples: 'GET /states; POST /services/light/turn_on {"entity_id":"light.kitchen"}',
      test: ['GET', '/'],
    ),
  ];

  static ConnDef? byId(String id) {
    for (final d in all) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Values for each connected service: id -> field -> value. Kept encrypted on the phone.
  static final Map<String, Map<String, String>> connected = {};

  /// User-made API connections: {id, name, base, header, prefix, key, notes}.
  static final List<Map<String, String>> custom = [];

  static String _fill(String t, Map<String, String> v) =>
      t.replaceAllMapped(RegExp(r'\{([a-z_]+)\}'), (m) => v[m.group(1)] ?? m.group(0)!);

  static String _clean(String base) {
    var b = base.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  // ---------------- tools ----------------
  static String toolName(String id) => 'app_${id.replaceAll(RegExp(r'[^a-z0-9_]'), '_')}';

  static const emailTools = {'email_list', 'email_read', 'email_search', 'email_send'};

  static bool isConnectorTool(String name) =>
      name == 'api_call' || emailTools.contains(name) || (name.startsWith('app_') && !name.startsWith('apps_'));

  static List<Map<String, dynamic>> definitions() {
    final out = <Map<String, dynamic>>[];
    for (final e in connected.entries) {
      final d = byId(e.key);
      if (d == null || d.kind != 'api') continue;
      out.add(_fn(toolName(d.id),
          'Use ${d.name} as the user (${d.blurb.toLowerCase()}). Base: ${_fill(d.base, {...e.value, 'token': '***', 'key': '***'})}. '
              '${d.examples.isEmpty ? '' : 'Examples: ${d.examples}'}',
          _httpProps(),
          ['method', 'path']));
    }
    for (final c in custom) {
      out.add(_fn(toolName('c_${c['id']}'),
          'Use the user\'s ${c['name']} API. Base: ${c['base']}. ${c['notes'] ?? ''}', _httpProps(), ['method', 'path']));
    }
    final mail = connectedEmails();
    if (mail.isNotEmpty) {
      final acct = {
        'account': {'type': 'string', 'description': 'Which email account: ${mail.join(', ')} (default: ${mail.first})'}
      };
      out.addAll([
        _fn('email_list', 'List the newest emails in the user\'s inbox (sender, subject, date, short preview, id).', {
          ...acct,
          'count': {'type': 'integer', 'description': '1-30, default 10'},
          'unread_only': {'type': 'boolean'},
          'folder': {'type': 'string', 'description': 'Default INBOX'},
        }, []),
        _fn('email_search', 'Search the user\'s email by words, sender or subject.', {
          ...acct,
          'query': {'type': 'string'},
          'from': {'type': 'string'},
          'count': {'type': 'integer'},
        }, []),
        _fn('email_read', 'Read one email in full by its id from email_list or email_search.', {
          ...acct,
          'id': {'type': 'integer'},
          'folder': {'type': 'string'},
        }, ['id']),
        _fn('email_send', 'Send an email from the user\'s account. Show the draft and get a yes first.', {
          ...acct,
          'to': {'type': 'string', 'description': 'Comma-separated addresses'},
          'cc': {'type': 'string'},
          'subject': {'type': 'string'},
          'body': {'type': 'string', 'description': 'Plain text'},
        }, ['to', 'subject', 'body']),
      ]);
    }
    return out;
  }

  static final Map<String, dynamic> apiCallTool = _fn(
    'api_call',
    'Make any HTTP request to a public API (GET, POST, PUT, PATCH, DELETE) and get the response. '
        'To call one of the user\'s connected apps with its saved login, set "connector" to its id '
        '(the app tools are usually easier). Returns status and body (JSON or text, trimmed).',
    {
      'method': {'type': 'string'},
      'url': {'type': 'string', 'description': 'Full https URL, or a path when "connector" is set.'},
      'headers': {'type': 'object', 'description': 'Extra headers.'},
      'query': {'type': 'object', 'description': 'Query parameters.'},
      'body': {'description': 'JSON body (object or array) or text.'},
      'body_type': {'type': 'string', 'enum': ['json', 'form', 'text']},
      'connector': {'type': 'string', 'description': 'Id of a connected app to sign the request with.'},
    },
    ['method', 'url'],
  );

  static Map<String, dynamic> _httpProps() => {
        'method': {'type': 'string', 'description': 'GET, POST, PUT, PATCH or DELETE'},
        'path': {'type': 'string', 'description': 'Path after the base, may include ?query'},
        'query': {'type': 'object', 'description': 'Optional query parameters'},
        'body': {'description': 'JSON body for POST/PUT/PATCH'},
      };

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> required) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': required},
        },
      };

  /// True when this call only reads (no confirmation needed). Anything not clearly a read asks first.
  ///
  /// Only the URL path counts (never the ?query, which anyone can fill), the read routes are anchored, and APIs that
  /// take actions over GET (Telegram's sendMessage, Slack's chat.postMessage) read only through their own allow-list.
  static bool isRead(String name, Map<String, dynamic> a) {
    if (name == 'email_send') return false;
    if (emailTools.contains(name)) return true;
    final m = (a['method'] ?? 'GET').toString().toUpperCase();
    final raw = '${a['path'] ?? a['url'] ?? ''}'.trim();
    String id = '';
    if (name == 'api_call') {
      id = '${a['connector'] ?? ''}'.trim();
      // A public API with no saved login: a GET carries nothing of the user's.
      if (id.isEmpty) return m == 'GET' || m == 'HEAD';
    } else {
      for (final d in all) {
        if (toolName(d.id) == name) id = d.id;
      }
    }
    // An absolute URL that leaves the app's own host is never sent (see [_call]); never call it a read either.
    if (raw.startsWith('http') && !_onOwnHost(id, raw)) return false;
    final path = pathOnly(raw);
    final seg = path.split('/').where((x) => x.isNotEmpty).lastOrNull ?? '';
    if (id == 'telegram') return telegramReads.contains(seg);
    if (id == 'slack') return _slackRead(seg);
    if (m == 'GET' || m == 'HEAD') return true;
    final body = jsonEncode(a['body'] ?? '');
    if (RegExp(r'(^|/)(search|query)$|/graphql$|(^|/)databases/[^/]+/query$').hasMatch(path)) {
      return !body.contains('mutation');
    }
    if (id == 'serper' || id == 'monday') return !body.contains('mutation');
    return false;
  }

  /// Telegram Bot API methods that only read. Everything else (send*, delete*, ban*, set*, edit*…) asks first.
  static const telegramReads = {
    'getMe', 'getUpdates', 'getChat', 'getChatMember', 'getChatMemberCount', 'getChatAdministrators', 'getFile',
    'getMyCommands', 'getMyName', 'getMyDescription', 'getWebhookInfo', 'getUserProfilePhotos', 'getStickerSet',
  };

  /// Slack Web API methods (`conversations.history`) that only read; Slack also takes writes over GET.
  static bool _slackRead(String method) {
    final verb = method.split('.').last;
    return const {'list', 'info', 'history', 'replies', 'members', 'test', 'lookupByEmail', 'messages', 'files', 'all', 'profile'}
            .contains(verb) ||
        verb.startsWith('get');
  }

  /// The path of [raw] (a path or a full URL) without its ?query or #fragment.
  static String pathOnly(String raw) {
    var p = raw;
    final cut = p.indexOf(RegExp(r'[?#]'));
    if (cut >= 0) p = p.substring(0, cut);
    if (p.startsWith('http')) p = Uri.tryParse(p)?.path ?? '';
    return p;
  }

  /// The host a connector's saved login may be sent to (its base, filled in).
  static String? hostOf(String id) {
    final d = byId(id);
    final v = connected[id];
    if (d == null) return null;
    final b = _clean(_fill(d.base, v ?? const {}));
    final u = Uri.tryParse(b.startsWith('http') ? b : 'https://$b');
    return (u == null || u.host.isEmpty || u.host.contains('{')) ? null : u.host.toLowerCase();
  }

  static bool _onOwnHost(String id, String url) {
    final u = Uri.tryParse(url);
    final h = hostOf(id);
    return u != null && u.scheme == 'https' && h != null && u.host.toLowerCase() == h;
  }

  /// Every saved secret (tokens, keys, passwords) of the connected apps, longest first.
  static List<String> secrets() {
    final out = <String>{};
    for (final e in connected.entries) {
      final d = byId(e.key);
      for (final f in d?.fields ?? const <ConnField>[]) {
        final v = e.value[f.key];
        if (f.secret && v != null && v.length >= 6) out.add(v);
      }
    }
    for (final c in custom) {
      final k = c['key'];
      if (k != null && k.length >= 6) out.add(k);
    }
    return out.toList()..sort((a, b) => b.length.compareTo(a.length));
  }

  /// [text] with every saved connector secret (and its URL-encoded form) replaced by •••. Error messages carry the
  /// request URL, and Telegram puts the bot token in the URL itself.
  static String scrub(String text) {
    var s = text;
    for (final k in secrets()) {
      s = s.replaceAll(k, '•••');
      final enc = Uri.encodeComponent(k);
      if (enc != k) s = s.replaceAll(enc, '•••');
    }
    return s;
  }

  static String appNameFor(String tool) {
    for (final d in all) {
      if (toolName(d.id) == tool) return d.name;
    }
    for (final c in custom) {
      if (toolName('c_${c['id']}') == tool) return c['name'] ?? 'the app';
    }
    if (emailTools.contains(tool)) return 'Email';
    return 'the app';
  }

  static Future<String> execute(String name, Map<String, dynamic> args) async => scrub(await _execute(name, args));

  static Future<String> _execute(String name, Map<String, dynamic> args) async {
    // Voice models send objects as JSON text; turn them back into objects.
    final a = {...args};
    for (final k in ['query', 'headers']) {
      if (a[k] is String && '${a[k]}'.trim().startsWith('{')) {
        try {
          a[k] = jsonDecode(a[k] as String);
        } catch (_) {}
      }
    }
    try {
      if (emailTools.contains(name)) return await _email(name, a);
      if (name == 'api_call') {
        final cid = (a['connector'] ?? '').toString();
        if (cid.isNotEmpty) {
          final d = byId(cid);
          final v = connected[cid];
          if (d == null || v == null) return 'Error: "$cid" is not connected.';
          return await _call(d, v, {...a, 'path': a['url']});
        }
        return await _raw(a);
      }
      for (final c in custom) {
        if (toolName('c_${c['id']}') == name) {
          final d = ConnDef(
            id: 'c_${c['id']}',
            name: c['name'] ?? 'API',
            category: '',
            blurb: '',
            fields: const [],
            base: c['base'] ?? '',
            headers: {
              if ((c['header'] ?? '').isNotEmpty) c['header']!: '${c['prefix'] ?? ''}{key}',
            },
            helpUrl: '',
            help: '',
          );
          return await _call(d, {'key': c['key'] ?? ''}, a);
        }
      }
      for (final e in connected.entries) {
        if (toolName(e.key) == name) {
          final d = byId(e.key);
          if (d == null) break;
          return await _call(d, e.value, a);
        }
      }
      return 'Error: that app is not connected any more.';
    } catch (e) {
      return 'Error: $e';
    }
  }

  static Future<String> _call(ConnDef d, Map<String, String> v, Map<String, dynamic> a) async {
    final method = (a['method'] ?? 'GET').toString().toUpperCase();
    var path = (a['path'] ?? '').toString().trim();
    final baseUrl = _clean(_fill(d.base, v));
    final base = Uri.tryParse(baseUrl.startsWith('http') ? baseUrl : 'https://$baseUrl');
    final own = base?.host.toLowerCase() ?? '';
    String url;
    if (path.startsWith('http')) {
      // The saved login goes only to the app's own host, over https. A link from a page, email or message must never
      // be able to send the token anywhere else.
      final u = Uri.tryParse(path);
      if (u == null || u.scheme != 'https' || own.isEmpty || u.host.toLowerCase() != own) {
        return 'Error: ${d.name} calls must stay on https://$own. Use a path after the base, like /v1/... (nothing was sent).';
      }
      url = path;
    } else {
      if (path.isNotEmpty && !path.startsWith('/') && !path.startsWith('.') && !path.startsWith('?')) path = '/$path';
      url = '$baseUrl${_fill(path, v)}';
      if (!url.startsWith('http')) url = 'https://$url';
    }
    var uri = Uri.parse(url);
    // A path like "@evil.example/x" or "//evil.example" could still move the request off the app's host.
    if (own.isNotEmpty && uri.host.toLowerCase() != own) {
      return 'Error: ${d.name} calls must stay on $own (nothing was sent).';
    }
    final q = <String, String>{...uri.queryParameters};
    d.query.forEach((k, t) => q[k] = _fill(t, v));
    final extra = a['query'];
    if (extra is Map) extra.forEach((k, val) => q['$k'] = '$val');
    uri = uri.replace(queryParameters: q.isEmpty ? null : q);
    final headers = <String, String>{'User-Agent': 'SubMacAgent/1.6', 'Accept': 'application/json'};
    d.headers.forEach((k, t) => headers[k] = _fill(t, v));
    if (d.basic != null) {
      String part(String t) => t.startsWith('=') ? t.substring(1) : _fill(t, v);
      headers['Authorization'] = 'Basic ${base64Encode(utf8.encode('${part(d.basic![0])}:${part(d.basic![1])}'))}';
    }
    return _send(method, uri, headers, a['body'], d.form ? 'form' : 'json');
  }

  static Future<String> _raw(Map<String, dynamic> a) async {
    final method = (a['method'] ?? 'GET').toString().toUpperCase();
    var uri = Uri.parse((a['url'] ?? '').toString().trim());
    if (!uri.hasScheme) return 'Error: give a full https URL.';
    final q = <String, String>{...uri.queryParameters};
    final extra = a['query'];
    if (extra is Map) extra.forEach((k, val) => q['$k'] = '$val');
    uri = uri.replace(queryParameters: q.isEmpty ? null : q);
    final headers = <String, String>{'User-Agent': 'SubMacAgent/1.6'};
    final h = a['headers'];
    if (h is Map) h.forEach((k, val) => headers['$k'] = '$val');
    return _send(method, uri, headers, a['body'], (a['body_type'] ?? 'json').toString());
  }

  static String _form(dynamic body) {
    final parts = <String>[];
    void add(String k, dynamic val) {
      if (val is Map) {
        val.forEach((kk, vv) => add('$k[$kk]', vv));
      } else if (val is List) {
        for (var i = 0; i < val.length; i++) {
          add('$k[$i]', val[i]);
        }
      } else if (val != null) {
        parts.add('${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent('$val')}');
      }
    }

    if (body is Map) body.forEach((k, val) => add('$k', val));
    return parts.join('&');
  }

  static Future<String> _send(String method, Uri uri, Map<String, String> headers, dynamic body, String type) async {
    final req = http.Request(method, uri)..headers.addAll(headers);
    if (body != null && method != 'GET' && method != 'HEAD') {
      var b = body;
      if (b is String && type != 'text') {
        try {
          b = jsonDecode(b);
        } catch (_) {}
      }
      if (type == 'form') {
        req.headers['Content-Type'] = 'application/x-www-form-urlencoded';
        req.body = b is String ? b : _form(b);
      } else if (type == 'text' || b is String) {
        req.headers.putIfAbsent('Content-Type', () => 'text/plain; charset=utf-8');
        req.body = '$b';
      } else {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(b);
      }
    }
    final streamed = await req.send().timeout(const Duration(seconds: 45));
    final r = await http.Response.fromStream(streamed);
    var text = utf8.decode(r.bodyBytes, allowMalformed: true);
    final ct = r.headers['content-type'] ?? '';
    if (ct.contains('html') && text.length > 2000) {
      text = text.replaceAll(RegExp(r'<script[\s\S]*?</script>|<style[\s\S]*?</style>'), ' ').replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ');
    }
    if (text.length > 6000) text = '${text.substring(0, 6000)}\n…[trimmed: ask for less, e.g. fewer fields or a smaller page]';
    final ok = r.statusCode >= 200 && r.statusCode < 300;
    return 'HTTP ${r.statusCode}${ok ? '' : ' (failed)'}\n$text';
  }

  /// Runs the connector's test request. Returns null when it worked, or a plain error.
  static Future<String?> test(ConnDef d, Map<String, String> v) async {
    try {
      if (d.kind == 'search') return null;
      if (d.kind == 'email') {
        final c = await _imap(d.id, v);
        await c.logout();
        return null;
      }
      final r = await _call(d, v, {
        'method': d.test[0],
        'path': d.test[1],
        if (d.test.length > 2) 'body': d.test[2],
      });
      if (r.startsWith('HTTP 2')) return null;
      final first = r.split('\n').first;
      final body = r.length > first.length ? r.substring(first.length).trim() : '';
      return scrub('$first ${body.length > 160 ? body.substring(0, 160) : body}');
    } catch (e) {
      return scrub('$e');
    }
  }

  // ---------------- email ----------------
  static const _servers = {
    'gmail': ['imap.gmail.com', 'smtp.gmail.com', '465'],
    'yahoo': ['imap.mail.yahoo.com', 'smtp.mail.yahoo.com', '465'],
    'icloud': ['imap.mail.me.com', 'smtp.mail.me.com', '587'],
    'zoho': ['imap.zoho.com', 'smtp.zoho.com', '465'],
  };

  static List<String> connectedEmails() => [
        for (final e in connected.entries)
          if (byId(e.key)?.kind == 'email') e.value['email'] ?? e.key,
      ];

  static MapEntry<String, Map<String, String>>? _account(dynamic which) {
    final w = (which ?? '').toString().toLowerCase();
    MapEntry<String, Map<String, String>>? first;
    for (final e in connected.entries) {
      if (byId(e.key)?.kind != 'email') continue;
      first ??= e;
      if (w.isNotEmpty && ((e.value['email'] ?? '').toLowerCase() == w || e.key == w)) return e;
    }
    return first;
  }

  static Future<ImapClient> _imap(String id, Map<String, String> v) async {
    final host = id == 'mail' ? (v['imap'] ?? '') : _servers[id]![0];
    final c = ImapClient(isLogEnabled: false);
    await c.connectToServer(host, 993, isSecure: true, timeout: const Duration(seconds: 20));
    await c.login(v['email'] ?? '', (v['password'] ?? '').replaceAll(' ', ''));
    return c;
  }

  static String _from(MimeMessage m) {
    final f = m.from;
    if (f == null || f.isEmpty) return '';
    final a = f.first;
    return (a.personalName ?? '').isNotEmpty ? '${a.personalName} <${a.email}>' : a.email;
  }

  static String _line(MimeMessage m) {
    var prev = (m.decodeTextPlainPart() ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (prev.isEmpty) {
      prev = (m.decodeTextHtmlPart() ?? '').replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    if (prev.length > 140) prev = '${prev.substring(0, 140)}…';
    final d = m.decodeDate();
    return '- id ${m.uid} | ${d == null ? '' : d.toLocal().toString().substring(0, 16)} | ${_from(m)} | '
        '${m.decodeSubject() ?? '(no subject)'}${m.isSeen ? '' : ' | UNREAD'}\n  $prev';
  }

  static Future<String> _email(String name, Map<String, dynamic> a) async {
    final acct = _account(a['account']);
    if (acct == null) return 'Error: no email account is connected. Ask the user to connect one in Settings > Connectors.';
    final id = acct.key, v = acct.value;
    if (name == 'email_send') {
      final s = id == 'mail' ? [v['smtp'] ?? '', '', '465'] : _servers[id]!;
      final port = int.parse(s[2]);
      final smtp = SmtpClient('submac.site', isLogEnabled: false);
      await smtp.connectToServer(s[1], port, isSecure: port == 465, timeout: const Duration(seconds: 20));
      await smtp.ehlo();
      if (port == 587) await smtp.startTls();
      await smtp.authenticate(v['email'] ?? '', (v['password'] ?? '').replaceAll(' ', ''), AuthMechanism.login);
      List<MailAddress> list(dynamic s) => [
            for (final x in '${s ?? ''}'.split(RegExp(r'[,;]')))
              if (x.trim().isNotEmpty) MailAddress(null, x.trim()),
          ];
      final msg = MessageBuilder.buildSimpleTextMessage(
        MailAddress(null, v['email'] ?? ''),
        list(a['to']),
        (a['body'] ?? '').toString(),
        cc: list(a['cc']),
        subject: (a['subject'] ?? '').toString(),
      );
      await smtp.sendMessage(msg);
      await smtp.quit();
      return 'Sent to ${a['to']}.';
    }
    final c = await _imap(id, v);
    try {
      final folder = (a['folder'] ?? 'INBOX').toString();
      if (folder.toUpperCase() == 'INBOX') {
        await c.selectInbox();
      } else {
        await c.selectMailboxByPath(folder);
      }
      if (name == 'email_read') {
        final uid = (a['id'] is num) ? (a['id'] as num).toInt() : int.tryParse('${a['id']}') ?? 0;
        final r = await c.uidFetchMessage(uid, 'BODY.PEEK[]');
        if (r.messages.isEmpty) return 'Error: email not found.';
        final m = r.messages.first;
        var body = m.decodeTextPlainPart() ?? '';
        if (body.trim().isEmpty) {
          body = (m.decodeTextHtmlPart() ?? '').replaceAll(RegExp(r'<style[\s\S]*?</style>'), ' ').replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'[ \t]+'), ' ');
        }
        if (body.length > 12000) body = '${body.substring(0, 12000)}…';
        return 'From: ${_from(m)}\nTo: ${m.to?.map((e) => e.email).join(', ') ?? ''}\nDate: ${m.decodeDate()}\n'
            'Subject: ${m.decodeSubject() ?? ''}\n\n$body';
      }
      final count = (((a['count'] is num) ? (a['count'] as num).toInt() : 10).clamp(1, 30)).toInt();
      String? criteria;
      if (name == 'email_search') {
        final parts = <String>[];
        final q = (a['query'] ?? '').toString().replaceAll('"', '');
        final f = (a['from'] ?? '').toString().replaceAll('"', '');
        if (q.isNotEmpty) parts.add('TEXT "$q"');
        if (f.isNotEmpty) parts.add('FROM "$f"');
        criteria = parts.isEmpty ? 'ALL' : parts.join(' ');
      } else if (a['unread_only'] == true) {
        criteria = 'UNSEEN';
      }
      List<MimeMessage> msgs;
      if (criteria == null) {
        final r = await c.fetchRecentMessages(messageCount: count, criteria: 'BODY.PEEK[]');
        msgs = r.messages;
      } else {
        final s = await c.uidSearchMessages(searchCriteria: criteria);
        final ids = s.matchingSequence?.toList() ?? <int>[];
        if (ids.isEmpty) return 'No emails found.';
        final pick = ids.length > count ? ids.sublist(ids.length - count) : ids;
        final r = await c.uidFetchMessages(MessageSequence.fromIds(pick, isUid: true), 'BODY.PEEK[]');
        msgs = r.messages;
      }
      if (msgs.isEmpty) return 'No emails.';
      msgs.sort((x, y) => (y.decodeDate() ?? DateTime(0)).compareTo(x.decodeDate() ?? DateTime(0)));
      return 'Account: ${v['email']}\n${msgs.map(_line).join('\n')}';
    } finally {
      try {
        await c.logout();
      } catch (_) {}
    }
  }
}
