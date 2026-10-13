#!/usr/bin/env python3
"""Exports misaki's cutlet kana->phoneme table and word list, and golden Japanese
phonemes from misaki JAG2P (cutlet: MeCab + UniDic-lite) for the native JapaneseG2P.
Needs tools/requirements-dev.txt:
  python3 -I tools/make_ja_golden.py third_party/models/misaki-ja Tests/NPCSpeechTests/Fixtures/misaki-ja-golden.json
"""
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import kokoro_engine  # noqa: E402
kokoro_engine.setup_imports()
from misaki import ja, cutlet  # noqa: E402

data = Path(sys.argv[1]); data.mkdir(parents=True, exist_ok=True)
json.dump(cutlet.HEPBURN, open(data / "hepburn.json", "w"), ensure_ascii=False, indent=0, sort_keys=True)
(data / "ja_words.txt").write_text("\n".join(sorted(cutlet.JA_WORDS)) + "\n")
g2p = ja.JAG2P()
corpus = [
    "こんにちは、東京へようこそ。", "海辺の祠の鈴は、嵐の前の晩にひとりでに鳴る。", "私は海辺の祠の守り人、アイコです。",
    "ちょっと待って！学校に行きました。", "コーヒーを一杯ください。", "原子炉の扉は封鎖されている。",
    "ようこそ、旅の方。", "……今は、お答えできません。", "嵐が来ますか？", "港は静かです。",
    "先生、ありがとうございます。", "この道をまっすぐ行ってください。", "彼は三日前に出発しました。",
    "部屋は一泊三千円です。", "雨の夜、祠の灯りが少し揺れる。", "誰にも言わないでください。",
    "あの船はもう戻らないでしょう。", "鐘が八回鳴ったら、門は閉まります。", "気をつけて、夜の海は危ないですよ。",
    "お茶でもいかがですか？", "すみません、よく分かりません。", "明日の朝、また来てください。",
    "本当に、それでいいのですか？", "昔々、この村に大きな龍が住んでいました。", "やめろ！",
    # Counters and numbers (sound changes: いっぱく, さんびゃく, ろっぽん, はっさい...).
    "一泊いくらですか？", "二泊三日の旅です。", "鉛筆を三本ください。", "六本の矢が刺さっている。", "八本の柱がある。",
    "十本の剣を集めた。", "猫が一匹、犬が三匹います。", "魚を六匹釣った。", "一回だけ試してみよう。", "三回目の挑戦だ。",
    "一杯の水をください。", "二杯目はいらない。", "三杯飲んだ。", "一階の部屋です。", "三階に上がってください。",
    "一人で来たのか？", "二人とも無事だ。", "三人の騎士が待っている。", "十人の兵士がいる。", "百人の村人が集まった。",
    "一つだけ教えてやろう。", "二つの道がある。", "八歳の子供です。", "二十歳になった。", "一分待ってください。",
    "三分で戻る。", "十分後に出発する。", "六時に起きる。", "九時に門が閉まる。", "四月一日に出発した。",
    "七日後に戻ります。", "二十日かかる。", "三千年前の遺跡だ。", "一万人の軍勢だ。", "百年に一度の嵐だ。",
    "千円札を一枚ください。", "金貨を五十枚持っている。", "十冊の本を読んだ。", "一頭の馬を買った。", "二足のブーツ。",
    # Katakana loanwords and names.
    "コーヒーとケーキをどうぞ。", "ギルドのマスターに会いたい。", "ドラゴンが現れた！", "ポーションを三つ買う。", "エルフの村はどこですか？",
    "ナイフとフォークを持ってきて。", "ドアを開けてくれ。", "パーティーに参加しますか？", "クエストを受けますか？", "モンスターに気をつけて。",
    "マルタさんの宿屋です。", "リースさんは門番だ。", "タムシンは何かを隠している。", "アイコさん、こんにちは。", "サルトレン号が行方不明だ。",
    # Honorifics, keigo, casual speech.
    "いらっしゃいませ。", "お待たせいたしました。", "ご注文はお決まりですか？", "少々お待ちください。", "申し訳ございません。",
    "ありがとうございました。", "またお越しください。", "お気をつけて。", "おはようございます。", "おやすみなさい。",
    "何だよ、うるさいな。", "知らねえよ。", "早く行けって！", "まあ、いいけど。", "ちょっと待ってよ。",
    "そうなんですか？", "なるほど、わかりました。", "それは困りましたね。", "大丈夫ですよ。", "心配しないで。",
    # Verb forms, te-forms, potential/causative/passive.
    "剣を抜いて戦え！", "扉を開けられない。", "彼に手紙を書かせた。", "宝を盗まれた。", "もう少し考えさせてください。",
    "ここで休んでもいいですか？", "地図を見せてもらえますか？", "鍵をなくしてしまった。", "一緒に行きましょう。", "言わなければよかった。",
    "思った通りだ。", "そう言っていた。", "聞いたことがない。", "見たことがありますか？", "食べてみたい。",
    # Long vowels, small tsu, n before various consonants.
    "王様の命令だ。", "東の塔へ向かえ。", "封印を解く方法がある。", "冒険者よ、ようこそ。", "空っぽの箱だ。",
    "切符を買って、列車に乗った。", "三枚の硬貨。", "新聞を読んでいる。", "本物の宝石だ。", "雰囲気がいい。",
    "銀貨と銅貨。", "反対側の岸に渡る。", "簡単なことだ。", "案内しましょう。", "信用できない。",
    # Onomatopoeia, emotion, questions.
    "ドキドキする。", "雨がザーザー降っている。", "ゆっくり休んでください。", "びっくりした！", "にこにこしている。",
    "どうして泣いているの？", "誰がやったんだ？", "いつ帰ってくるの？", "どこへ行くつもりだ？", "何が欲しいんだ？",
    # Sentences with mixed scripts and punctuation.
    "「静かに」と彼は言った。", "――もう遅い。", "えっと……どうしよう。", "はい、そうです！", "いいえ、違います。",
    "この剣はＡランクだ。", "ＨＰが少ない。", "レベル１０のモンスター。", "第３章が始まる。", "２０２６年の春。",
]
lines = [{"text": t, "phonemes": g2p(t)[0]} for t in corpus]
json.dump({"source": "misaki 0.9.4 ja.JAG2P(cutlet) + fugashi + unidic-lite 1.0.8", "lines": lines},
          open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
for l in lines[:6]: print(l["text"], "→", l["phonemes"])
print("table", len(cutlet.HEPBURN), "words", len(cutlet.JA_WORDS))
