"""Builds assets/bots/business.json: the knowledge pack of SubMac's built-in Business adviser bot.
Facts were checked on official or company pages on 2026-10-21 (see the Sources piece). Re-check them before changing
rates, fees or steps. Run: python3 tools/bots/business/build.py"""
import json, os

CHECKED = "2026-10-21"
K = []
def add(title, text):
    K.append({"title": title, "text": text.strip(), "kind": "text", "file": ""})

add("How to use this knowledge / Sida aqoontan loo isticmaalo", f"""
This pack was checked on {CHECKED}. Laws, tax rates, fees and app rules change. Before you give a number the user will
act on (a tax rate, a fee, a deadline, a price), say it is from your knowledge checked in October 2026 and tell them where
to confirm it (the official site in the Sources piece). If you can use the web, check the official page first.
Never invent a price, fee, phone number, address, office, law number, review or company detail. If you do not know, say so.
Somalia has different authorities: the Federal Government (Mogadishu/Banadir and federal member states), Somaliland
(Hargeisa) and Puntland (Garowe) each run their own business registration and taxes. Always ask where the business is
before you talk about registration or tax. Puntland details are NOT in this pack: tell the user to confirm with Puntland's
Ministry of Commerce and Ministry of Finance.
""")

add("Your business tools and how to use them / Qalabkaaga ganacsiga", """
You keep the user's real business books on their phone with the biz_ tools. Use them; never keep numbers only in chat.
First time: biz_setup set (business name, phone, address, currency, accounts such as Cash, EVC Plus, ZAAD, bank; payment_info
for invoices, e.g. "EVC Plus 61xxxxxxx or Sifalo Pay link"). Ask only for what you need; tax_rate only if the user confirms it.
Daily work (record at once, confirm in one short line with the new balance):
- "I sold 3 abayas at $35, Hodan paid $50" -> biz_sale lines + customer + paid. Cash or which wallet? -> account.
- "Paid rent $200" -> biz_expense expense, category Rent. "Bought 20 bags of rice at $18 from Bakaaro" -> biz_expense purchase lines.
- "Ahmed paid $40 of his debt" -> biz_payment payment_in contact Ahmed. Owner takes money home -> owner_out. Moving cash to EVC -> transfer.
- Stock: biz_stock add/update/adjust/list/low/history. Stock count -> update qty (it records the difference).
- Customers and suppliers: biz_contacts (statement shows every entry with a running balance; pdf for sending).
- Debts: biz_debts list; reminder makes a polite Somali or English message the user sends themselves (WhatsApp/SMS).
- Tasks: biz_tasks for staff and shop jobs with due dates.
- Documents: biz_document invoice, quote, receipt, delivery_note, purchase_order -> numbered PDF. Show the ```file card.
  biz_sale document=receipt gives a receipt right after a sale.
- Reports: biz_report summary (dashboard), profit_loss, cashbook, sales, expenses, stock, debts, tasks. format chat for a quick look
  (paste the ```diagram chart cards it returns), pdf for a printable report with charts, xlsx for Excel.
- Mistakes: biz_records list/search, delete the wrong entry, record it again. export = full Excel backup.
- Maths: biz_calc for every price, margin, markup, break-even, discount, tax, zakat or instalment figure. Never calculate in your head.
Spreadsheets and data analysis:
- A user sends an Excel/CSV (in uploads/): data_sheet describe first (columns, totals, gaps), then query: filters, compute (formulas
  like "[Unit price] * Qty"), group_by + aggregate (sum, avg, count, min, max, median, distinct), pivot, sort, limit, chart, save_as xlsx.
- Explain what the numbers mean in plain words: best and worst items, trends, what to do next.
- New spreadsheet (budget, price list, stock sheet, payroll, cash-flow plan): make_document kind xlsx with columns and rows; formulas such as
  "=SUM(B2:B20)" or "=C2*D2" work in cells. Put totals in the last row.
Graphics: chat charts are ```diagram blocks: {"type":"bars"|"donut"|"line","title":"...","unit":"$","items":[{"label":"Rice","value":120}]}.
For a designed picture (an infographic, a sales poster, a price-list flyer, a logo) use code_media kind image or svg: 2-3 colours,
big clear numbers, Somali or English text exactly as agreed.
""")

add("Starting a business step by step / Bilaabida ganacsi tallaabo tallaabo", """
1. Idea and customer: who exactly buys, what problem it solves, why they would buy from you and not the shop next door.
2. Test small first (tijaabo): sell 10-20 units to real customers (friends, a WhatsApp group, a Facebook post) before
   buying big stock or renting a shop. Count what sold, at what price, and what people asked for.
3. Numbers before money: start-up costs (stock, equipment, rent deposit, licence, phone/data), monthly fixed costs
   (rent, salaries, internet, electricity), cost per unit, selling price, and break-even (see the Pricing piece).
4. Money: own savings, family, partners (put the agreement in writing: who puts in what, who decides, how profit and loss
   are shared), Islamic finance from banks (murabaha, mudaraba, musharaka, ijara), and saving groups (hagbad/ayuuto).
   Avoid riba-based loans; many Somali users want Sharia-compliant options only.
5. Register and get a licence where the business operates (see the registration pieces). Get a tax number (TIN).
6. Payments: a mobile money merchant number and, for online sales, a gateway or payment links (see Sifalo Pay).
7. Records from day one: every sale, every expense, stock in and out (see Bookkeeping).
8. Marketing: a Facebook page, WhatsApp Business catalogue, short videos, happy-customer photos (with permission).
9. Review every month: profit, cash, best and worst products, what to change.
A one-page business plan: problem, customer, product, price, competitors, how you reach customers, start-up cost, monthly
costs, expected sales for 6 months, who runs what, risks.
""")

add("Online business ideas that fit Somalia / Fikradaha ganacsi online", """
Ideas that work with a phone and mobile money (give the user honest pros and cons, never promise income):
- Social commerce: clothes, abayas/hijabs, perfume (cadar/uunsi), cosmetics, phone accessories, electronics, home goods,
  sold through Facebook, Instagram, TikTok and WhatsApp with delivery by boda/bajaj or pick-up.
- Food: home-made cakes, sambuusa, catering for weddings and events, meal delivery for offices.
- Services: graphic design, video editing, social media management for shops, website building, translation
  (Somali-English-Arabic), typing and CV writing, phone repair, tutoring and Quran lessons online.
- Digital products and courses: paid lessons, e-books, templates, sold with payment links.
- Diaspora market: Somalis abroad paying for gifts, Qurbe-Joog services, property checks, goods sent to family. Card
  payments matter here (see Sifalo Pay and cards).
- Freelancing for international clients (Upwork, Fiverr and similar): needs a way to receive money; check each platform's
  payout options for Somalia before starting.
Avoid and warn against: betting/gambling, pyramid or "invest $100 earn $1000" schemes, selling counterfeit or banned goods,
crypto "signals" groups, anything haram or illegal.
""")

add("Sifalo Pay: getting paid online / Sifalo Pay", """
What it is (from sifalopay.com, checked 2026-10-21): a payments platform for Somalia, Somaliland, Djibouti and Ethiopia.
It brings mobile money and cards together in one account, so a business can collect money online and withdraw it.
Payment methods it lists: EVC Plus, ZAAD, Sahal (eSahal), eDahab, Premier Wallet, Visa and Mastercard.
Ways to get paid:
- Payment links: create a link (sifalo.co/...), send it on WhatsApp, Facebook or TikTok, the customer pays. No website needed.
  Good for products, services, event tickets, courses. There are also crowdfunding links for causes and campaigns.
- Hosted checkout and API: a developer connects a website or app (REST API, docs at developer.sifalopay.com).
- Plugins: WooCommerce (WordPress plugin "Sifalo Pay") and Odoo. Shopify was listed as "coming soon".
Withdrawals: to mobile money; bank withdrawals and mass payouts need the Business plan. Withdrawals are supported in
Somalia, Somaliland, Djibouti and Ethiopia; payments can come from most countries.
Signing up: pay.sifalo.com/auth/signup. Personal accounts need email, address and a valid personal ID. Business accounts
also need business registration documents and the main administrator's ID. Identity checks (KYC) and two-factor login apply.
Cost: personal accounts have no monthly fee. Transaction fees differ by payment method and are shown inside the Sifalo Pay
portal; do not quote a fee you have not seen there. A Business plan adds sub-accounts, branded checkout, team users,
bank withdrawals, WhatsApp billing, payroll.
Note from Sifalo's terms: services are for legally established businesses; one account per business; age 18+.
Support: built-in chat in the portal. Sales: sifalo.co/book.
Practical tips: test with a small amount first; put the payment link in your Facebook/Instagram bio and WhatsApp catalogue;
send a receipt or confirmation after each payment; reconcile Sifalo payouts with your sales book every week.
""")

add("Mobile money and other payment options / Lacag mobile iyo habab kale", """
Main mobile money wallets (operator): EVC Plus (Hormuud), ZAAD (Telesom), Sahal (Golis), eDahab (Somtel / Dahabshiil
group), Premier Wallet (Premier Bank). Which one customers use depends on the region and network.
Options for a seller:
- A merchant / business number with the operator, so customers pay you directly. Ask the operator's office for the
  current requirements and fees (do not guess them).
- A gateway that accepts several wallets and cards in one place (Sifalo Pay, or bank gateways such as the Premier Payment
  Gateway launched by Premier Bank with Mastercard in July 2024 for international card payments).
- Cash on delivery for new customers who do not trust online payment yet.
Good habits: keep business money separate from personal money (a separate SIM/wallet or account); write down every payment
with the customer name and order; never send goods before the payment shows in your own wallet (scammers send fake SMS
screenshots); protect your PIN.
""")

add("Selling on Facebook and Instagram / Ka iibinta Facebook iyo Instagram", """
Set-up:
1. Create a Facebook Page for the business (not a personal profile) and link an Instagram professional account.
2. Use Meta Business Suite (business.facebook.com) to manage both, reply to messages and plan posts.
3. Fill the page: clear name, logo, cover photo, phone/WhatsApp button, location or delivery area, opening hours, prices or
   "price in inbox" (better: show prices, buyers trust it more).
4. WhatsApp Business app: business profile, catalogue with photos and prices, quick replies, labels (new order, paid,
   delivered), away message.
Content that sells: real photos of the real product in good daylight; short videos (15-45 s) showing use, size and quality;
customer reviews and delivery photos (with permission); offers with a clear deadline; behind-the-scenes; post consistently
(for example once a day) and answer every comment and message fast.
Ads (Meta Ads Manager, adsmanager.facebook.com): choose an objective (Messages/WhatsApp for local sales, Traffic, Sales),
set location, age and interests, start small (for example a few dollars a day), run for several days, then keep what brings
messages or sales and stop the rest. Ads must follow Meta's advertising rules (no misleading claims, no banned products).
Paying for ads: Meta usually needs a card that works online (Visa/Mastercard debit or prepaid). Some Somali banks issue
Mastercard debit/prepaid cards (for example Premier Bank). Check what payment methods your Ads Manager shows; never buy
"ad accounts" or cards from strangers.
Measure: cost per message, how many messages became orders, cost per sale. If an ad costs more than the profit per sale,
change the ad or the product.
""")

add("Selling on TikTok / Ka iibinta TikTok", """
Important: in August 2023 the Federal Government of Somalia announced a ban on TikTok and Telegram. Whether and how it is
enforced has varied; tell the user to check the current situation and the rules where they live before relying on TikTok,
and to have Facebook, Instagram and WhatsApp as well.
How sellers use TikTok: a business account; short vertical videos with a hook in the first 2 seconds; show the product in
use, before/after, unboxing, prices and how to order; trending sounds (licensed ones for business); post often; reply to
comments with videos; go LIVE to sell; send buyers to WhatsApp or a payment link (bio link).
TikTok Ads: TikTok Ads Manager (ads.tiktok.com). Sign up, set business info and time zone (it cannot be changed later),
build a campaign, add payment. Available payment methods depend on the billing country; check them in Ads Manager under
billing before planning a budget. TikTok Shop is not available in every country; do not promise it.
""")

add("Pricing and profit / Qiimeynta iyo faa'iidada", """
Cost per unit = buying price + transport/shipping + customs or fees + packaging + delivery (if you pay it) + payment fee.
Gross profit per unit = selling price - cost per unit. Margin % = gross profit / selling price x 100.
Markup % = gross profit / cost x 100. (A 50% markup is a 33% margin.)
Break-even units per month = monthly fixed costs / gross profit per unit.
Example: cost $6, price $10, profit $4 per unit; rent + salary + internet $400 a month -> 400 / 4 = 100 units to break even.
Pricing methods: cost-plus (cost + markup), competitor-based (check 3-5 sellers), value-based (what it is worth to the
customer). Include your own time. Do not compete on price alone; compete on trust, speed, quality and service.
Discounts: a 20% discount on a 30% margin product needs about 3 times the sales to earn the same profit. Use bundles or
free delivery instead of deep cuts.
""")

add("Bookkeeping and accounting basics / Xisaabinta aasaasiga ah", """
Keep it simple but every day:
- Sales book (buugga iibka): date, item, quantity, price, customer, how paid (cash, EVC, ZAAD, card, credit).
- Expense book (kharashka): date, what, amount, receipt kept.
- Cash book: money in and out of the till and each wallet; count cash at day end and compare.
- Credit book (deynta): who owes you (amaah/deyn) and who you owe, with due dates. Follow up weekly.
- Stock book (see Inventory).
Monthly reports:
- Profit and loss: sales - cost of goods sold = gross profit; gross profit - expenses = net profit.
- Cash flow: cash at start + cash in - cash out = cash at end. Profit is not cash: stock and credit sales tie up cash.
- Balance sheet (simple): what the business owns (cash, stock, equipment, money owed to it) minus what it owes = owner's equity.
Rules: never mix personal and business money; pay yourself a fixed salary; keep receipts (tax law requires records such as
sales and purchase invoices, receipts, payroll, bank statements and asset registers); back up records (Google Sheets,
an accounting app, photos of receipts).
Tools: a notebook, Excel/Google Sheets, or accounting software (for example Odoo, which also connects to Sifalo Pay).
Zakat: many owners pay zakat on business assets (cash + stock at selling/market value + money owed that will be paid,
minus short-term debts) at 2.5% when above nisab and held a lunar year. For rulings, refer them to a trusted scholar.
""")

add("Inventory and stock control / Maareynta badeecada (stock)", """
- Keep a stock list per item: code, name, size/colour, cost, price, quantity in hand, reorder level.
- Record every movement: stock in (purchases), stock out (sales), returns, damaged/expired.
- Count physically every week for fast items and every month for all; compare with the book and find the gap (theft,
  mistakes, damage).
- Reorder level = daily sales x days until new stock arrives + safety stock. Example: 5 a day x 10 days + 15 = 65.
- ABC: A items (few products, most of the money) get the closest attention; C items (many cheap products) less.
- FIFO: sell older stock first, essential for food, cosmetics and medicine dates.
- Slow movers: bundle, discount, or stop buying them. Dead stock is locked cash.
- Imports: plan for shipping time, customs and currency changes; do not put all cash into one big shipment.
- Tools: a spreadsheet with formulas, barcode apps, or POS/ERP software (Odoo has inventory).
""")

add("Retail shop management / Maamulka dukaanka", """
Location and layout: foot traffic, visibility, security; best sellers at eye level; clean, well lit, prices shown.
Daily routine: open on time, count float, check stock gaps, record every sale, end-of-day cash count and wallet check,
lock up and note what to reorder.
Customer service: greet, know the products, honest advice, easy exchanges with clear rules, keep a customer list
(with permission) to send offers on WhatsApp.
Staff: clear duties, fair pay on time, training, cash handled by named people only, regular stock counts, never one person
doing selling, cash and stock checks alone.
Suppliers: compare at least 2-3, agree prices and credit terms in writing, check goods on arrival, build good relations.
Credit sales: limit them, write them down, agree dates; unpaid credit is the top killer of small shops.
Grow: add delivery, a WhatsApp catalogue, a Facebook page, loyalty offers, and sell online with payment links.
""")

add("Management, staff and growth / Maamulka, shaqaalaha iyo kobaca", """
- Goals: 3-5 clear monthly targets (sales, profit, new customers, stock turnover), checked every week.
- Roles: write who does what; a simple job description per person; one person responsible for each task.
- Hiring: test skills, check references, a written contract (pay, hours, duties, notice). Follow local labour law; employers
  must withhold and pay employees' income tax where required (see tax pieces).
- Cash control: two people for big payments, daily reconciliation, receipts for everything.
- Customers: track complaints and fix the cause; ask happy customers for reviews.
- Partnerships: written agreement on capital, roles, profit sharing, decisions, exit and disputes. Islamic partnership
  forms: musharaka (both put capital), mudaraba (one capital, one work).
- Growth only when the base works: steady profit, good records, a second person who can run things.
- Risk: insurance where available (takaful), backups of records, more than one supplier, cash reserve of 2-3 months costs.
""")

add("Stocks and investing basics / Saamiyada iyo maalgashiga", """
- A share (saami) is part ownership of a company; value can go up or down, and you can lose money.
- Somalia: many Somali companies sell shares directly to the public rather than through a big exchange. Before buying
  any share: ask for the company's registration, audited accounts, the share agreement in writing, and how and to whom you
  can sell later. Whether a licensed stock exchange or broker operates changes over time: check the current position (web,
  Central Bank of Somalia, Ministry of Finance) before saying one exists or not.
- International stocks: need a broker that accepts Somali residents; many do not. Warn about apps and agents promising
  fixed high returns: that is the classic sign of a scam.
- Halal investing: avoid companies whose main business is haram (interest banking, alcohol, gambling); many use halal
  screening (for example AAOIFI standards). Refer detailed rulings to a scholar.
- Rules for beginners: invest only money you will not need for years; spread it out; understand what you buy; keep the
  business's emergency cash separate.
- Never give personal investment advice as a licensed adviser would ("buy X now"); explain options, risks and questions to ask.
""")

add("Tax in Somalia (Federal) / Canshuurta Dowladda Federaalka", """
Source: Somalia Income Tax Manual (Ministry of Finance, Nov 2025) for the Income Tax Law 2025 and Income Tax Regulations 2025.
Checked 2026-10-21. The Law and Regulations are the authority if the manual differs.
- Who registers: anyone (person or entity) earning business or investment income in Somalia registers with the Inland
  Revenue / Revenue Directorate on Form TR1 and gets a TIN. Company registration on the eBusiness portal also links to tax.
- Small individual businesses (Presumptive Tax Regime, PTR): resident individuals with business turnover not above USD 50,000
  a year (rolling average of 3 years). Tax is paid quarterly: the higher of USD 37.5 or 1.5% of the quarter's turnover.
  Example: quarter sales USD 10,000 -> 1.5% = USD 150 (higher than 37.5) -> pay USD 150.
- Individuals/sole proprietors above that: Personal Income Tax on taxable profit (sales minus purchases and legitimate
  business expenses). Resident yearly bands: 0-1,200: 0%; 1,200-6,000: 6%; 6,000-18,000: 12%; above 18,000: 18%.
- Corporations (resident), as the manual lists: USD 150 for sales under USD 10,000; 1.5% for sales above 10,000 and below
  50,000; 15% for sales over 50,000 (large and medium taxpayers, on taxable profit). Non-resident corporations: 18% flat.
- Business deductions: purchases and legitimate business expenses; depreciation at prescribed rates; past losses. Not
  private expenses; not capital expenses (they are depreciated). Total deductions cannot exceed 95% of income.
- Instalments: estimate the year's tax and pay in 4 quarterly instalments by 31 March, 30 June, 30 September,
  31 December; reconcile and file the annual return by 31 March of the next year.
- Employers: withhold employees' PIT monthly and pay by the 15th of the next month. Monthly resident bands: 0-100: 0%;
  100-500: 6%; 500-1,500: 12%; above 1,500: 18%. Non-resident employees: 18% flat.
- Withholding examples from the manual: rent on real estate 5%, rent on vehicles/machinery 10%, service fees 10%.
- Sales tax: the federal government applies a sales tax on goods and services (standard rate reported as 5%); confirm how it
  applies to the user's goods with the Revenue Directorate.
- Records: keep sales and purchase invoices, receipts, payroll, bank statements, asset registers.
- Penalties exist for failing to register, file, pay or keep records (Revenue Administration Law/Regulation).
Federal member states may also collect their own taxes and fees; local municipal fees (for example Banadir) are separate.
Official: mof.gov.so (Publications > Inland Revenue) and revenuedirectorate.gov.so.
""")

add("Registering a business in Somalia (Federal) / Diiwaangelinta ganacsiga", """
Portal: Somali Business Registration and Licensing System (SBRS/SBRLS) by the Federal Ministry of Commerce and Industry
(MoCI) at ebusiness.gov.so (also linked from moci.gov.so > Services > Business Registration).
Steps (MoCI): create an account, choose the entity type, upload documents, pay the fee, receive the certificate.
Typical documents named on the government trade portal: application and registration forms, company profile, notarized
form, two passport photos per shareholder, copies of shareholders' IDs/passports. Name reservation comes first.
Fees on the official fee schedule (Banadir, checked 2026-10-21): name reservation USD 20; private/public limited and other
company registration USD 50; change of name USD 20; copy of records USD 20. Licences for certain activities have their own
fees. Always confirm the current fee on ebusiness.gov.so/fees.
After registration: tax registration (TIN) with the Revenue Directorate, any sector licence, municipal/local permits,
and for foreign investors the SOMINVEST investment certificate.
Law: Company Law (2019/2020) and Company Law Regulation 001/2021 (moci.gov.so > Laws & Regulations).
Ministry office: Mohamoud Harbi Road, behind the Somali National Theater, Mogadishu. eBusiness contact page lists phone
+252613121213.
""")

add("Somaliland: registration, licence and tax / Somaliland", """
Registration and licences: Somaliland Business Registration and Licensing Services (BRLS), brls.govsomaliland.org, run with
the Ministry of Trade and Tourism. Online: name search and reservation, register a business, get a TIN through the link with
the Ministry of Finance, apply for or renew a business licence, update or close a business.
Licence steps (BRLS): create an account, choose new business license, fill and submit, ministry review, invoice by SMS or
email and Pay Now, Director of Trade approval, Minister's final review, download the digitally signed licence.
Licence fees are on BRLS fee schedules by activity (for example general trading import/export) in Somaliland shillings;
confirm there. Licensing law: Business Licensing Act No. 98/2021.
Tax (Ministry of Finance & Economic Development, slmof.org, checked 2026-10-21): register with the Inland Revenue Department
before starting business; the TIN certificate is free. Tax types listed: Goods & Services Tax 5%, Payroll tax 6%, Rental
income tax 12.3% for individuals (annual, by 30 April of the next year; companies include rent in their income tax return).
Business profit tax: confirm the current rate and any small-business rules with the Inland Revenue Department (the Revenue
Act 2016 applies).
""")

add("Somali business words / Ereyada ganacsiga", """
profit = faa'iido; loss = khasaare; capital = raasumaal; sales = iib; expense = kharash; stock/goods = badeeco; debt/credit =
deyn/amaah; customer = macmiil; supplier = alaab-keene/soo-iibiye; price = qiimo; discount = qiimo-dhimis; tax = canshuur;
licence = liisan/ruqsad; registration = diiwaangelin; invoice = qaansheeg/faktuur; receipt = rasiid; partner = shuraako/lammaane;
salary = mushahar; budget = miisaaniyad; market = suuq; advertising = xayaysiis; online shop = dukaan online.
""")

add("Sources (checked 2026-10-21)", """
- Sifalo Pay: https://sifalopay.com (FAQ, payment methods, withdrawals); signup https://pay.sifalo.com/auth/signup;
  API https://developer.sifalopay.com; terms https://www.sifalo.com/sifalo-pay-terms/ ; WooCommerce plugin
  https://wordpress.org/plugins/sifalo-pay/
- Federal registration: https://ebusiness.gov.so and fees https://ebusiness.gov.so/fees ; https://moci.gov.so/en/service/business-registration
- Federal tax: Income Tax Manual (Nov 2025) https://mof.gov.so/sites/default/files/Publications/Somalia%20Income%20Tax%20Manual_English%20Version.pdf ;
  https://revenuedirectorate.gov.so
- Somaliland: https://brls.govsomaliland.org/site/business-licensing ; https://www.slmof.org/tax-types ; https://www.slmof.org/taxpayer-registration/
- Premier Payment Gateway (Premier Bank and Mastercard, July 2024): https://www.premierbank.so
- TikTok ban announcement (Aug 2023): https://www.aljazeera.com/news/2023/8/26/outcry-in-somalia-over-government-decision-to-ban-tiktok-telegram
- TikTok Ads: https://ads.tiktok.com/business/en ; Meta: https://business.facebook.com
""")

out = {"id": "business", "checked": CHECKED, "knowledge": K}
here = os.path.dirname(os.path.abspath(__file__))
dst = os.path.join(here, "..", "..", "..", "assets", "bots", "business.json")
os.makedirs(os.path.dirname(dst), exist_ok=True)
json.dump(out, open(dst, "w"), ensure_ascii=False, indent=1)
print(len(K), "pieces,", sum(len(k["text"]) for k in K), "chars ->", os.path.normpath(dst))
