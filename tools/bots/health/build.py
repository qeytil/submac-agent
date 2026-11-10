"""Builds assets/bots/health.json: the knowledge pack of Telesia's built-in Health adviser bot (Caafimaad).
Facts follow WHO guidance and Somalia Ministry of Health documents, checked on 2026-10-21 (see the Sources piece).
Re-check before changing numbers, schedules or phone numbers. Run: python3 tools/bots/health/build.py"""
import json, os

CHECKED = "2026-10-21"
K = []
def add(title, text):
    K.append({"title": title, "text": text.strip(), "kind": "text", "file": ""})

add("How to use this knowledge / Sida aqoontan loo isticmaalo", f"""
Checked on {CHECKED}. You are a health adviser, not a doctor. You give general health information and help people decide
WHEN and WHERE to get care. You never give a sure diagnosis, never choose or change a medicine dose, never tell anyone to stop a
prescribed medicine, and never suggest antibiotics, injections or strong medicines without a prescription.
Order of every symptom conversation:
1. health_check first (danger signs). EMERGENCY = first line says go to hospital / call an ambulance now.
2. Ask only what changes the advice: age, how long, pregnant or breastfeeding, other signs, long-term illness, medicines taken.
3. Explain in plain words what it could be, home care that is safe, and the exact signs that mean "go now".
4. Offer to save it (health_log symptom, health_visits) and to make a summary for the doctor (health_report).
Emergency numbers (checked Oct 2026): Mogadishu: Aamin Ambulance 999, free, 24 hours. Official Somalia numbers: ambulance 999,
police 888, fire 555, but they do not work in every city. Advise every family to save the number of their nearest hospital and of a
driver who can take them at night. Never invent a hospital name, phone number, doctor or price.
Facts come from WHO and the Somalia Ministry of Health. Guidance can change: for a medicine, vaccine or treatment decision the
clinic, doctor or pharmacist has the final word.
Language: answer in the user's language. Somali words used in this pack: qandho (fever), shuban (diarrhoea), matag (vomiting),
qufac (cough), neef (breath), duumo (malaria), daacuun (cholera), jadeeco (measles), qaaxo (TB), dhiig kar (high blood pressure),
sonkorow / macaan (diabetes), uur (pregnancy), foolka (labour), dhallaan (newborn), tallaal (vaccine), nafaqo darro (malnutrition),
fuuqbax (dehydration), daawo (medicine), isbitaal (hospital), xarun caafimaad (health centre), farmashiye (pharmacy).
""")

add("Your health tools and how to use them / Qalabkaaga caafimaadka", """
You keep a private family health book on the phone with the health_ tools. Use them; never keep health facts only in chat.
- health_check: run FIRST for any symptom, injury or worry. Map the user's words (Somali or English) to sign codes, add numbers
  (temp_c, breaths_per_min, bp, sugar, spo2, muac_cm, days, age_months). Follow the level it returns.
- health_people: add each person once (start with the user: name "Me", relation me), with sex, birth date, blood group,
  allergies and long-term conditions. Allergies are checked when a medicine is added.
- health_meds: add a medicine only with the dose the prescription, package or pharmacist gives. It returns the reminder times:
  offer schedule_task (one per time, repeat daily; for a short course say it stops on the end date). taken / missed / today / history.
- health_log: readings: bp "130/85", sugar (+ context fasting / random / after_meal), temp, weight, height, pulse, spo2, muac, and
  symptom or note text. Each reading comes back with its meaning (OK / WATCH / SEE A DOCTOR / EMERGENCY). trend gives a ```diagram
  chart card: paste it as it is.
- health_pregnancy: set from the last period (lmp), a scan, or the clinic's due date; status, visits (8 check-ups with dates),
  danger_signs, end (after birth: add the baby with health_people to track vaccines).
- health_child: vaccines (Somalia schedule from the birth date: given, due, overdue), given (mark codes or all_due), muac.
- health_visits: save what the doctor found, tests and results, advice and the next visit; offer a reminder for the next visit.
- health_calc: bmi, due_date, age, convert (sugar mg/dL and mmol/L, C and F, kg and lb, cm and inches), ors (how to mix), water.
  No medicine doses.
- health_report: summary of one person for the doctor (chat, pdf with charts, xlsx). Show the ```file card.
Privacy: health data stays on the phone. Ask before sharing it with anyone; never put it in a public post.
Pictures: when a user sends a photo of a rash, wound, medicine box or test result, describe what you can see, read the text exactly,
but say a photo cannot replace an exam. Read prescriptions and lab papers carefully and save the results with health_visits.
""")

add("Danger signs: when to go to hospital now / Calaamadaha khatarta", """
ANY AGE: not breathing well or blue lips; unconscious or cannot be woken; fits (suuxdin); chest pain or pressure; signs of stroke
(face drooping, arm weak, slurred speech: note the time it started); heavy bleeding; severe burn; poisoning or an overdose; severe
allergic reaction (swollen face or throat); severe sudden belly pain; vomiting blood or black stool; head injury with vomiting or
sleepiness; very high blood pressure with chest pain, breathlessness, weakness or confusion; thoughts of suicide.
CHILDREN 2 months to 5 years (WHO IMCI general danger signs): cannot drink or breastfeed; vomits everything; has had fits;
very sleepy or unconscious. Also: chest pulls in when breathing; fast breathing (50 or more a minute at 2-12 months, 40 or more at
1-5 years: count for one full minute while calm); stiff neck; severe dehydration (sunken eyes, very weak, skin pinch goes back very
slowly); MUAC under 11.5 cm or both feet swollen.
YOUNG BABIES under 2 months: not feeding well; fits; fast breathing (60 or more); severe chest indrawing; fever 37.5 C or more or
temperature under 35.5 C; moves only when touched; yellow palms or soles, or yellow in the first day; red or pus around the cord.
PREGNANCY: bleeding; severe headache or blurred vision; fits; swollen face and hands; fever; severe belly pain; difficult breathing;
baby moving less; waters break; labour over 12 hours. AFTER BIRTH: heavy bleeding, fever, smelly discharge, fits.
URGENT (same day): fever 39 C or more, fever for 3 days, blood in stool, diarrhoea over 14 days, painful urination with fever,
fever with rash, yellow eyes, animal bite (rabies), a spreading red hot swelling, a deep cut, a broken bone.
""")

add("First aid at home / Gargaarka degdegga ah", """
Call for help first and keep yourself safe. Do: 
- Bleeding: press firmly with a clean cloth for 10 minutes without lifting; raise the limb; go to hospital if it does not stop.
- Burns: cool under clean running water for 20 minutes; remove rings and tight clothes; cover with clean cling film or cloth.
  NOT butter, oil, toothpaste, eggs or mud. Burns on the face, hands, genitals, larger than the person's palm, or in a child = hospital.
- Choking: if they can cough, let them cough. If they cannot breathe or speak: adult and child: 5 firm back blows between the shoulder
  blades then 5 abdominal thrusts; baby: face down on your arm, 5 back blows, then 5 chest pushes with two fingers. Repeat; hospital.
- Fits (suuxdin): move hard things away, put something soft under the head, do not hold them down, put NOTHING in the mouth.
  After it stops, lay them on their side. A fit over 5 minutes, a first fit, a fit in pregnancy or a child with fever = hospital.
- Fainting: lay flat, raise the legs, loosen clothes, fresh air. If not awake in a minute, or chest pain: hospital.
- Unconscious but breathing: recovery position on the side; nothing by mouth.
- Not breathing: call for help, start chest compressions (hard and fast in the centre of the chest, about 100-120 a minute).
- Snake bite: keep calm and still, keep the limb below the heart, remove rings, go to hospital. No cutting, sucking, tight
  tourniquet, ice or herbs.
- Poisoning (kerosene, bleach, pills, pesticides): do not make them vomit; bring the bottle or box to the hospital.
- Heat stroke (hot, confused, stops sweating): move to shade, cool with water and fanning, sips of water if awake, hospital.
- Broken bone: keep it still with a splint (stick and cloth), do not try to straighten it; hospital.
- Dog bite: wash the wound with soap and running water for 15 minutes; go the same day for rabies vaccine.
Harmful traditional treatments to gently discourage: burning the skin with hot iron (gubid) for illness; cutting the uvula or
removing "false teeth" in babies; putting dung, ash or herbs on wounds or the cord; forcing a person in a fit to smell things.
""")

add("Fever and malaria / Qandho iyo duumo", """
Fever is the body fighting an infection. Measure if possible (normal about 36.5-37.5 C; fever 38 C or more).
Home care: fluids, light clothes, rest, keep breastfeeding. Paracetamol helps comfort: use the dose on the package for the age and
weight; never more than the package allows in 24 hours. Do not wrap a feverish child in blankets.
Malaria (duumo): spread by mosquitoes, more common along the Juba and Shabelle rivers and in the rainy seasons (Gu and Deyr); less
in the dry north. WHO rule: test before treating (a rapid test (RDT) or microscope at the health centre), then take the full course
of the medicine prescribed (usually an artemisinin combination). Do not treat every fever as malaria and do not take leftover tablets.
Severe malaria (fits, very sleepy, cannot drink, very pale, yellow eyes, dark urine, breathing hard) = hospital now.
Prevention: sleep under an insecticide-treated net every night, especially children and pregnant women; remove standing water.
Other causes of fever in Somalia include pneumonia, urinary infections, dengue, typhoid and measles. The Widal test for typhoid
is often wrong; a doctor should decide.
Go today: fever 39 C or more, fever 3 days or more, fever with rash, stiff neck, painful urination, or any danger sign; a baby
under 3 months with fever.
""")

add("Diarrhoea and cholera / Shuban iyo daacuun", """
The danger in diarrhoea is losing water (fuuqbax). Treatment for most cases at home:
1. ORS after every loose stool (health_calc ors explains the mix). Breastfeeding continues.
2. Zinc tablets for children for 10-14 days, given by the health worker or pharmacist.
3. Keep eating: soft foods, porridge, rice, banana; small meals often.
Signs of dehydration: thirsty, dry mouth, few urine, sunken eyes; severe = very weak, cannot drink, skin pinch goes back very slowly.
Cholera (daacuun) and acute watery diarrhoea (AWD): sudden heavy watery diarrhoea like rice water, with vomiting; can kill in hours.
Start ORS at once and go to the nearest cholera treatment centre or health centre. Somalia has had cholera outbreaks every year
since 2017, worst in droughts, floods and crowded camps.
Go today: blood in stool, diarrhoea over 14 days, high fever, a baby under 6 months, a malnourished child, or any danger sign.
No antibiotics or anti-diarrhoea medicines for children unless a health worker prescribes them.
Prevention: safe water (boil it, or chlorine tablets / liquid as the label says, keep it covered), wash hands with soap after the toilet
and before cooking and eating, use latrines, cook food well, wash fruit, and take the oral cholera vaccine during campaigns.
""")

add("Cough, pneumonia and TB / Qufac, oof iyo qaaxo", """
Colds and coughs: most get better in 7-10 days with fluids, rest, honey for children over 1 year (never honey under 1 year), and
steam. Antibiotics do not help colds.
Pneumonia (oof): cough or difficult breathing with fast breathing or chest indrawing; in children a leading cause of death in Somalia.
Count breaths for one minute (fast = 60+ under 2 months, 50+ at 2-12 months, 40+ at 1-5 years). Fast breathing = clinic today;
chest indrawing, cannot drink or blue lips = hospital now. Treatment is an antibiotic prescribed by a health worker; the full course.
Tuberculosis (qaaxo): cough 2 weeks or more, coughing blood, fever, night sweats, weight loss. TB is common in Somalia and is
curable. Testing and treatment at TB centres are usually free; treatment takes at least 6 months and must not stop early, even when
the person feels well, or TB becomes drug-resistant. People living with a TB patient, especially children, should be checked.
Cover coughs, open windows, and wear a mask around others while coughing.
Asthma: wheeze and tight chest; the inhaler the doctor prescribed, and avoid smoke (charcoal, cigarettes, shisha).
""")

add("Vaccines for children / Tallaalka carruurta", """
Vaccines are free at government health centres and MCH clinics. Somalia routine schedule (Ministry of Health immunization policy):
- Birth (up to 2 weeks): BCG (TB) and polio drops (OPV0)
- 6 weeks: Penta 1 (diphtheria, tetanus, whooping cough, hepatitis B, Hib), polio drops 1
- 10 weeks: Penta 2, polio drops 2
- 14 weeks: Penta 3, polio drops 3, polio injection (IPV 1)
- 9 months: measles 1, polio injection 2 (IPV 2)
- 15 months: measles 2
Pneumococcal (PCV, against pneumonia and meningitis) and rotavirus (against severe diarrhoea) vaccines were added nationwide in April
2025; the clinic gives them with the 6, 10 and (PCV) 14-week visits. The clinic's card is the final word. Pregnant women get tetanus
(Td) vaccine at antenatal visits.
Missed vaccines can be caught up late: never skip because the child is "too old"; go to the clinic with the card.
Mild fever or a sore arm after a vaccine is normal for a day or two. A child with a cold can still be vaccinated.
Measles (jadeeco) kills and blinds children in Somalia; two doses protect. A child with measles needs vitamin A from the health worker,
plenty of fluids and food, and a clinic visit for any danger sign, eye problem or breathing difficulty.
Vaccines do not cause infertility or autism; they are allowed in Islam and used in all Muslim countries. Polio campaigns are extra
doses: they are safe on top of routine vaccines.
Use health_child vaccines with the child's birth date to show what is due.
""")

add("Feeding children and malnutrition / Nafaqada carruurta", """
- Breastfeed within the first hour after birth. The first yellow milk (colostrum) is the baby's first vaccine: give it.
- Only breast milk for the first 6 months: no water, sugar water, tea, camel or goat milk, or herbs; breast milk has enough water
  even in the heat. Breastfeed often, day and night.
- From 6 months add soft family foods 2-3 times a day, rising to 3-4 meals plus snacks by 9-12 months: porridge (mixed with milk,
  oil or egg), mashed beans, lentils, liver and meat, eggs, fish, mashed vegetables and fruit (banana, mango, papaya). Keep
  breastfeeding to 2 years or more.
- Wash hands and use a clean cup and spoon; avoid feeding bottles.
Malnutrition (nafaqo darro): watch for weight loss, a very thin child, swollen feet (press the top of both feet for 3 seconds: a dent
that stays = oedema = urgent), poor appetite, frequent illness. MUAC (the coloured arm band) for children 6-59 months: red under
11.5 cm = severe (go to a nutrition centre now); yellow 11.5-12.4 = moderate (join a nutrition programme); green 12.5+ = normal.
Treatment with ready-to-use therapeutic food (RUTF, "plumpy") at nutrition sites is free. RUTF is medicine for that child only:
do not share or sell it.
Vitamin A and deworming every 6 months from the health centre or campaigns protect children.
""")

add("Pregnancy and childbirth / Uurka iyo dhalmada", """
Antenatal care (WHO): at least 8 contacts: first before 12 weeks, then at 20, 26, 30, 34, 36, 38 and 40 weeks
(health_pregnancy visits gives the dates). Each checks blood pressure, weight, urine, the baby's growth and heartbeat, anaemia.
Take iron and folic acid every day as given by the clinic (prevents anaemia and birth defects); tetanus vaccine (Td); a scan before
24 weeks if available; sleep under a mosquito net.
Eat one extra small meal a day, with beans, lentils, meat, liver, eggs, milk, dark leafy vegetables and fruit. Avoid khat, cigarettes
and shisha, and any medicine not approved by a health worker.
Birth plan from 7 months: which hospital or health centre, transport day and night, money saved, who goes with her, a blood donor
from the family. Give birth with a skilled health worker in a facility: many Somali mothers die from bleeding after birth and from
eclampsia, which a facility can treat.
Danger signs: health_pregnancy danger_signs. Any one = go now.
Fasting in Ramadan: many healthy pregnant women can fast, but Islam allows pregnant and breastfeeding women not to fast if they fear for
themselves or the baby; she should discuss it with her doctor, and stop fasting if she feels dizzy, the baby moves less, or she is
very thirsty.
After birth: rest, eat well, breastfeed, and postnatal checks within 24 hours, at day 3, at 1-2 weeks and at 6 weeks.
Postpartum sadness lasting more than 2 weeks, or thoughts of harming herself or the baby, needs help: be kind and get her to a doctor.
Birth spacing: WHO advises waiting at least 2 years after a birth before the next pregnancy; it protects mother and child. Islamic
scholars widely allow spacing between births; the clinic can explain methods that are safe while breastfeeding.
""")

add("The newborn baby / Dhallaanka", """
- Dry the baby, skin to skin on the mother's chest, and breastfeed within the first hour.
- Keep warm: a hat and covers, skin to skin; delay the first bath for at least 24 hours.
- Cord: keep it clean and dry, nothing on it (no ash, oil, dung or herbs) unless the health worker gives chlorhexidine.
  It falls off in 5-15 days.
- BCG and polio drops at birth (health_child).
- Normal: sneezing, hiccups, small white spots on the nose, feeding 8-12 times in 24 hours, 6 or more wet nappies a day after day 5.
- Mild yellow skin after day 2 that fades is common; yellow on the first day, yellow palms or soles, or yellow and not feeding = hospital.
- Danger signs (go now): not feeding, fits, fast breathing (60+), chest indrawing, fever 37.5 C or more, cold body (under 35.5 C),
  very sleepy or floppy, red or pus around the cord, many skin pustules.
- Low birth weight or premature babies: kangaroo care (skin to skin many hours a day), frequent breastfeeding, and follow-up.
- Do not cut the uvula, remove "false teeth" or give anything but breast milk.
""")

add("Diabetes / Sonkorowga (macaanka)", """
Diabetes = too much sugar in the blood. Signs: thirst, passing a lot of urine, tiredness, weight loss, wounds that heal slowly,
blurred vision, infections. Many people have no signs: adults over 40, overweight people and those with a family history should test.
Diagnosis (WHO): fasting sugar 126 mg/dL (7.0 mmol/L) or more, or HbA1c 6.5% or more, confirmed by a health worker.
Usual targets for many adults with diabetes (the doctor sets the personal target): fasting about 80-130 mg/dL, 2 hours after a meal under
180, HbA1c under 7%. Use health_log sugar to record and trend readings.
Daily care: medicines or insulin every day exactly as prescribed, even when feeling well; check sugar as the doctor advised.
Food with Somali meals: smaller portions of white rice, pasta, canjeero, laxoox, bread and sabaayad; more beans, lentils, vegetables,
salad, fish, chicken; fruit instead of sweets; tea and coffee with little or no sugar; avoid soft drinks and juice. Walk 30 minutes
on most days. Stop smoking.
Low sugar (under 70 mg/dL, shaking, sweating, confusion): 15 g fast sugar (3 teaspoons of sugar in water or half a glass of juice), recheck
in 15 minutes, repeat if still low, then eat. Not able to swallow = hospital.
Very high sugar with vomiting, deep fast breathing or drowsiness = hospital now.
Feet: look at them daily, wash and dry well, never walk barefoot, see a health worker for any wound.
Ramadan: see the doctor 6-8 weeks before; insulin and some tablets need changes. Break the fast at once if sugar falls under 70 mg/dL
or rises over 300 mg/dL, or if there are signs of low sugar or illness (IDF-DAR guidance). Islam excuses the sick from fasting.
""")

add("High blood pressure, heart and stroke / Dhiig karka, wadnaha iyo istaroogga", """
High blood pressure (dhiig kar) usually has no symptoms but causes stroke, heart attack and kidney failure. WHO: hypertension is 140/90
or more on repeated readings; most people should aim under 140/90, and under 130 (top number) when they also have heart disease,
diabetes or kidney disease, as their doctor decides.
Measure right: sit quietly 5 minutes, back supported, feet flat, arm at heart level, no tea, coffee or cigarettes 30 minutes before;
take two readings a minute apart; record with health_log bp.
Medicines every day, even when feeling well; never stop or share them. If side effects bother you, tell the doctor.
Life changes: less salt (WHO: under 5 g a day, about one teaspoon, including salt in food): less salted meat (oodkac/muqmad),
sauces, stock cubes, salty snacks; more vegetables and fruit; walk; lose extra weight; stop smoking and shisha; avoid khat.
Heart attack signs: chest pain or pressure, pain spreading to the arm, jaw or back, sweating, breathlessness = hospital now.
Stroke signs (FAST): Face drooping, Arm weak, Speech strange, Time to go to hospital now; note when it started.
""")

add("Using medicines safely / Isticmaalka daawada si ammaan ah", """
- Take medicines exactly as prescribed; finish antibiotic courses; never share or reuse old prescriptions.
- Antibiotics only with a prescription. Taking them for colds, flu or most diarrhoea does not help and breeds resistant germs, a serious
  problem in Somalia where antibiotics are sold without prescription.
- Buy from a licensed pharmacy with a pharmacist; check the expiry date, an unbroken seal and the same packaging as usual. Fake or poor
  medicines exist: if a medicine looks or works differently, show it to the pharmacist.
- Paracetamol is safe at the package dose but too much damages the liver: count all products (many cold medicines contain it).
  Adults usually no more than 4 g in 24 hours unless a doctor says otherwise.
- Ibuprofen and diclofenac can hurt the stomach and kidneys; avoid them in late pregnancy, with stomach ulcers, kidney disease or
  dehydration unless a doctor approves.
- "Injections work better" is not true; unnecessary injections risk infections such as hepatitis B and C and HIV.
- Do not use skin-lightening creams: many contain mercury or strong steroids that damage the skin and kidneys.
- Tell every doctor all medicines and herbs you take, any allergies, and if you are pregnant or breastfeeding.
- Keep medicines high and locked away from children; keep insulin cool.
- Missed a dose: follow the leaflet or ask the pharmacist; usually do not double.
Use health_meds to record what each person takes and set reminders.
""")

add("Women's health / Caafimaadka haweenka", """
Periods: normal cycles are 21-35 days, bleeding 2-7 days. See a health worker for very heavy bleeding (soaking a pad in an hour),
bleeding between periods or after menopause, severe pain, or no period for 3 months without pregnancy.
Anaemia is common (tired, pale, short of breath): iron-rich foods (liver, meat, beans, lentils, dark leafy vegetables) with vitamin C fruit,
and iron tablets if the clinic advises.
FGM (gudniinka fircooniga iyo sunnaha): WHO says every type of FGM is harmful and has no health benefit. It causes bleeding, infection,
pain, urine and period problems, difficult childbirth, and deaths of mothers and babies. Somalia has one of the highest rates in the world.
Many Somali religious scholars state Islam does not require it. Speak about it kindly and factually; women who already had it can get help
for problems at a clinic, including opening (defibulation) before childbirth.
Breast health: know how your breasts normally look and feel; a lump, skin dimpling, nipple discharge or a change = see a doctor soon.
Cervical cancer: screening where available; the HPV vaccine protects girls where it is offered.
Fistula (leaking urine or stool after a hard labour) can be repaired by surgery: it is not the woman's fault.
""")

add("Mental health / Caafimaadka maskaxda", """
Mental illness is common and treatable; it is not a weakness or a lack of faith. Decades of conflict, displacement and loss mean many
Somalis live with trauma, depression and anxiety.
Depression: sad or empty most days for 2 weeks or more, no interest, sleep and appetite changes, tiredness, feeling worthless.
Anxiety: constant worry, racing heart, fear. Trauma (PTSD): nightmares, flashbacks, always on guard after a terrible event.
Psychosis: hearing voices, strange beliefs, confused speech; needs a doctor.
Help: listen without judging; encourage sleep, walking, prayer and time with trusted people; reduce khat (it worsens sleep, anxiety and
psychosis). See a doctor or mental health service; medicines and talking therapy work. Faith and ruqyah can comfort, alongside medical
care, not instead of it.
Never chain or lock a person up (still seen in some places): it is harmful and abusive; take them to a health facility.
Suicide warning signs: talking about wanting to die, feeling a burden, giving things away, saying goodbye. Ask directly and calmly
("Are you thinking of ending your life?"); asking does not put the idea in their head. Stay with them, remove means, and get help now:
this is an emergency (health_check sign suicidal).
""")

add("Staying healthy / Ilaalinta caafimaadka", """
- Water: drink safe water (boiled, chlorinated, or from a protected source) kept covered; wash hands with soap.
- Food: more vegetables, fruit, beans and lentils, fish and chicken; less sugar (tea, sweets, soft drinks), less salt and fried food,
  smaller portions of white rice and pasta. A plate: half vegetables, a quarter protein, a quarter grains.
- Move: adults at least 150 minutes of moderate activity a week (WHO), for example 30 minutes walking on 5 days; children 60 minutes a day.
- Sleep 7-9 hours for adults.
- Avoid tobacco, shisha and khat: they cause cancer, heart disease, mouth disease, sleep and mental problems, and cost the family money.
- Teeth: brush twice a day with fluoride toothpaste (the miswak is good too), little sugar between meals, a dentist for pain or holes.
- Heat: drink often, rest in shade at midday, watch children and old people.
- Checks: blood pressure every year from age 18 (more often if high); sugar test from 40 or earlier with risk; eye checks with diabetes.
- Prevent malaria with nets, cholera with safe water, measles with vaccines.
""")

add("Common problems at home / Dhibaatooyinka caadiga ah", """
Short home care plus when to see a health worker:
- Headache: rest, water, food, paracetamol at the package dose. Go now: sudden worst-ever headache, with fever and stiff neck, after a head
  injury, with weakness or confusion, or in pregnancy.
- Back pain: keep moving gently, warmth. Go: with weakness or numbness in the legs, loss of bladder control, fever, or after a fall.
- Heartburn: smaller meals, less spicy, oily food and tea late at night, do not lie down after eating. Go: black stool, vomiting blood,
  weight loss, difficulty swallowing.
- Constipation: more water, fruit, vegetables, beans, walking. Go: severe pain, blood, vomiting.
- Worms: deworming tablets from the health centre; wash hands, wear shoes.
- Scabies (cuncun habeenkii): itchy rash worse at night, often the whole family: the health worker treats everyone at the same time and
  bedding is washed.
- Red eye with discharge: clean with boiled cooled water, do not share towels. Go: pain, poor vision, a newborn, or after an injury.
- Ear pain: go if pus, fever, or it lasts over 2 days in a child.
- Urine burning: more water; go the same day for a test, at once with fever or back pain, and always in pregnancy.
- Wounds: wash with clean water and soap, cover; go for deep, dirty or bite wounds (tetanus, rabies) or spreading redness.
""")

add("Health services in Somalia / Adeegyada caafimaadka", """
- Government health centres and MCH (mother and child health) clinics give vaccines, antenatal care, family planning, child checks and
  nutrition screening, usually free.
- Nutrition sites (OTP and stabilisation centres) treat malnourished children free.
- TB centres test and treat TB free.
- Cholera treatment centres open during outbreaks.
- Hospitals: public, NGO-supported and private hospitals exist in the main cities; services and prices differ. Ask the family, the health
  centre or the local health office which one handles emergencies, births, surgery or children at night, and save its number.
- Pharmacies are many; choose a licensed one with a trained pharmacist.
- Health authorities: the Federal Ministry of Health and Human Services (moh.gov.so), the Somaliland Ministry of Health Development, and
  the Puntland Ministry of Health (moh.pl.so) run public services and campaigns in their areas.
- Diaspora families: you can still keep the health book for parents back home, set reminders for their medicines, and send them the PDF
  summary for their doctor.
Never invent a hospital, doctor, phone number or price. If the user needs a specific place, search the web and say it should be confirmed by
phone.
""")

add("Sources (checked 2026-10-21)", """
- WHO fact sheets: https://www.who.int/news-room/fact-sheets/detail/diarrhoeal-disease ; .../cholera ; .../malaria ; .../tuberculosis ;
  .../measles ; .../hypertension ; .../diabetes ; .../female-genital-mutilation ; .../physical-activity ; .../salt-reduction ;
  .../depression ; .../suicide ; .../antimicrobial-resistance (all under https://www.who.int/news-room/fact-sheets/detail/)
- WHO recommendations on antenatal care for a positive pregnancy experience (2016): 8 contacts.
- WHO Integrated Management of Childhood Illness (IMCI) chart booklet: danger signs, fast breathing cut-offs, young infant signs.
- WHO and UNICEF guidance on ORS, zinc, breastfeeding and complementary feeding; WHO guideline on hypertension (2021).
- Somalia immunization policy (Ministry of Health, WHO country planning):
  https://extranet.who.int/countryplanningcycles/sites/default/files/country_docs/Somalia/somalia_immunization_policy.pdf
- PCV and rotavirus introduction in Somalia, 22 April 2025: https://www.gavi.org/news/media-room/somalia-launches-nationwide-vaccination-against-pneumococcal-disease-and-rotavirus
- Aamin Ambulance (Mogadishu, free, hotline 999): https://aaminambulance.org/
- Somalia emergency numbers (ambulance 999, police 888, fire 555; unreliable in places): https://www.gov.uk/foreign-travel-advice/somalia/getting-help
- IDF-DAR Diabetes and Ramadan Practical Guidelines (2021): when to break the fast.
""")

out = {"id": "health", "checked": CHECKED, "knowledge": K}
here = os.path.dirname(os.path.abspath(__file__))
dst = os.path.join(here, "..", "..", "..", "assets", "bots", "health.json")
os.makedirs(os.path.dirname(dst), exist_ok=True)
json.dump(out, open(dst, "w"), ensure_ascii=False, indent=1)
print(len(K), "pieces,", sum(len(k["text"]) for k in K), "chars ->", os.path.normpath(dst))
