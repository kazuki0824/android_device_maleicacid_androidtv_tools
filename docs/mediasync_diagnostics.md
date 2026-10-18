# MediaSync診断の製品ビルド統合

`libstagefright`はAndroidのメディア処理を担うC++共有ライブラリで、
`frameworks/av/media/libstagefright/MediaSync.cpp`のnative MediaSyncも含む。
TISのAPKを更新するだけでは、この実装への診断追加は反映されない。

## このビルドで取り込む変更

`91-tv_component.xml`は、再生修正・診断・採取スクリプトを含む
tv PR #209の`60fbe4cb24fd54dcdef0375f9f7e102463962cce`に固定する。
従来参照したPR #116の先端ではなく、その上にある#206・#207・#209の
変更を含む確認構成である。診断パッチだけを取得する変更ではない。

`get_android_qcow2.sh`の通常実行で、同期後の既存パッチ適用一覧から
`tis/platform_patches/lineage-22.1/frameworks_av_mediasync_diagnostics.patch`
を`frameworks/av`へ適用する。パッチ本体はtv側を正本とし、ここへ複製しない。
同期失敗やパッチ欠落・適用失敗時は、未反映のまま製品ビルドへ進まない。

既存の適用スクリプトは対象リポジトリを`git reset --hard`する。
そのため実行前に手で当てたパッチは消える。今回の一覧登録により、
reset後に診断パッチを適用し直す。作業中の変更があるAndroid treeでは
この既存の破壊的処理に注意する。

既存の`diskimage-vda`製品ビルドで、変更した`libstagefright`とTISを含む
imageを生成し、通常のimage導入手順で両方を更新する。
`m libstagefright MaleicacidTvInput`だけの成功は、端末導入完了を意味しない。
Exact-mode用のJava/JNI/private listenerパッチは追加しない。
診断出力は採取時の`log.tag.MediaSync=DEBUG`で有効になり、常時DEBUGにはしない。

## 診断パッチがない場合の違い

| 解析 | TISだけを更新した場合 |
|---|---|
| 黒画面・トーストの契機 | TISの再生不能理由・入力欠落・Codecエラーの調査は可能。下位層の原因すべてが分かるとは限らない。 |
| 停止不能 | Javaスタックと別途採取するnativeスタックで調査可能。このパッチはnativeスタック採取の必須条件ではない。 |
| MediaSync内部の映像経路 | 入力buffer・PTS・表示予定時刻・出力queue結果を結び付ける追加ログが得られない。 |
| 旧映像の所属世代 | 用意した世代→MediaSync buffer→SurfaceFlingerの対応付けに必要な中間証拠が欠ける。 |

パッチがあってもqueue成功は画面表示成功ではない。最終表示の判定には
SurfaceFlingerの記録と外部撮影が必要で、採取欠落時は断定しない。
採取コマンド・成立条件は[tvの統合手順](https://github.com/kazuki0824/tv/blob/60fbe4cb24fd54dcdef0375f9f7e102463962cce/tis/INTEGRATION.md#黒画面停止不能旧映像の診断採取)
を正本とする。ビルドrevision・Framework差分・fingerprintと同じビルドの
symbolsも保持する。

## 確認範囲

ホストでのBash構文検査・パッチ適用確認は、Android製品ビルドや実機検証の
代替ではない。製品ビルド後、採取中に`PLAYBACK_SYNC_CREATE`・
`PLAYBACK_SYNC_INPUT`・`PLAYBACK_SYNC_OUTPUT`が現れることと、
対象layerのbuffer記録がtraceに存在することを確認する。
この統合だけで黒画面・停止不能・旧映像再表示の解消を保証しない。
