# Custom ROM GSF ID 登録および Google Play ストア有効化手順

`get_android_qcow2.sh`（または `migration/a15/get_android_qcow2.sh`）で生成した Android TV / LineageOS 22.1 イメージで、個人の custom ROM 端末として GSF ID を確認・登録し、Google Play ストアを利用できるようにする手順です。

本ビルドは `vendor/gapps_tv` を取り込み、`GoogleServicesFramework`、`PrebuiltGmsCorePano`、`Tubesky` などを組み込む構成となっています。

> **注意:** GSF ID の登録は Play Protect 認証そのものを取得する手続きではありません。

---

## 想定フロー

```text
get_android_qcow2.sh で qcow2 作成
        ↓
Android TV 起動
        ↓
GSF / GMS / Play Store package 確認
        ↓
ネットワーク接続
        ↓
Play Store を一度起動
        ↓
GSF ID 取得
        ↓
Google の custom ROM 用ページで登録
        ↓
Play Store データのみ初期化
        ↓
再起動
        ↓
Play Store 起動
        ↓
Google アカウントでログイン
        ↓
アプリ取得確認
```

---

## 1. Google コンポーネント確認

デバイスが認識されていることを確認し、必要なパッケージのパスを確認します。

```bash
adb wait-for-device

adb shell pm path com.google.android.gsf
adb shell pm path com.google.android.gms
adb shell pm path com.android.vending
```

無効化されている場合は必要に応じて有効化します。

```bash
adb shell pm enable --user 0 com.android.vending
adb shell pm enable --user 0 com.google.android.gms
adb shell pm enable --user 0 com.google.android.gsf
```

## 2. Play ストアを一度起動

初回起動を行い、GSF ID 生成に必要な初期化を走らせます（ネットワーク接続済みであることを確認してください）。

```bash
adb shell monkey \
    -p com.android.vending \
    -c android.intent.category.LEANBACK_LAUNCHER \
    1
```

## 3. GSF ID 取得

まず root 不要の方法で取得を試みます。

```bash
adb shell content query \
    --uri content://com.google.android.gsf.gservices \
    --where "name='android_id'" \
    --projection value
```

取得できない場合、`adb root` が可能なビルドではデータベースから直接確認します。

```bash
adb root
adb wait-for-device

USER_ID="$(adb shell am get-current-user | tr -d '\r')"
echo "Android user = $USER_ID"

adb shell "sqlite3 \
/data/user/$USER_ID/com.google.android.gsf/databases/gservices.db \
'select value from main where name=\"android_id\";'"
```

## 4. GSF ID の10進 / 16進確認

```bash
GSF_ID="$(
    adb shell "sqlite3 \
    /data/user/\$(am get-current-user)/com.google.android.gsf/databases/gservices.db \
    'select value from main where name=\"android_id\";'" \
    | tr -d '\r'
)"

echo "GSF ID decimal = $GSF_ID"

python3 -c '
import sys
n=int(sys.argv[1])
print("GSF ID hex     = {:016x}".format(n))
' "$GSF_ID"
```

> **注意:** `Settings.Secure.ANDROID_ID` ではなく、GSF の `android_id` を対象とします。

## 5. Google 側への登録

ブラウザで以下の登録ページにアクセスし、Google アカウントでログインして GSF ID（16進または10進）を登録します。

👉 **https://www.google.com/android/uncertified/**

※ この操作は Google アカウントへの紐付けが必要なため、adb のみでは完結しません。

## 6. 登録後、Play ストアを再初期化

登録完了後、Play ストアのデータを初期化して再起動します。

```bash
adb shell am force-stop com.android.vending
adb shell pm clear com.android.vending

adb reboot
adb wait-for-device

adb shell pm enable --user 0 com.android.vending
adb shell monkey \
    -p com.android.vending \
    -c android.intent.category.LEANBACK_LAUNCHER \
    1
```

> [!WARNING]
> `adb shell pm clear com.google.android.gsf` は絶対に実行しないでください。
> GSF のデータを消去すると GSF ID が再生成され、Google 側に登録した ID と不一致になります。

## 7. Play ストアのアイコンが表示されない場合のトラブルシューティング

```bash
adb shell dumpsys package com.android.vending \
    | grep -E 'enabled=|hidden=|suspended='
```

Play ストアが直接起動するか確認します。

```bash
adb shell monkey -p com.android.vending 1
```

直接起動できる場合は、Play ストア本体ではなく Android TV ランチャー側の表示条件を確認してください。

---

## 完了チェックリスト

- [x] `com.google.android.gsf` が存在する
- [x] `com.google.android.gms` が存在する
- [x] `com.android.vending` が存在する
- [x] GSF ID を取得できる
- [x] Google 側へ GSF ID を登録できる
- [x] 再起動後に Play ストアを起動できる
- [x] Google アカウントでログインできる
- [x] Play ストアから Android TV 対応アプリを取得できる
