# MediaSync診断の製品ビルド統合

`libstagefright`はAndroidのメディア処理を担うC++共有ライブラリで、
`frameworks/av/media/libstagefright/MediaSync.cpp`のnative MediaSyncも含む。
TISのAPKを更新するだけでは、この実装への診断追加は反映されない。

## ビルドと導入

`get_android_qcow2.sh`を実行すると、`patches/lineage-22.1/apply_patches.sh`が
同ディレクトリの`frameworks_av_mediasync_diagnostics.patch`を
`frameworks/av`へ適用する。手動での事前適用は不要。
既存スクリプトは対象リポジトリを`git reset --hard`してから適用するため、
対象treeに保存していない変更がある場合は先に退避する。

TISの取得revisionは`91-tv_component.xml`を参照する。
`diskimage-vda`の生成後、通常のimage導入手順で対象ABIの
`libstagefright`とTISを両方更新する。
`m libstagefright MaleicacidTvInput`だけの成功は端末導入完了を意味しない。

診断出力は採取時の`log.tag.MediaSync=DEBUG`で有効になる。
採取操作は下記のTIS統合手順に従う。

## 診断パッチがない場合の違い

| 解析 | TISだけを更新した場合 |
|---|---|
| 黒画面・トーストの契機 | TISの再生不能理由・入力欠落・Codecエラーの調査は可能。下位層の原因すべてが分かるとは限らない。 |
| 停止不能 | Javaスタックと別途採取するnativeスタックで調査可能。このパッチはnativeスタック採取の必須条件ではない。 |
| MediaSync内部の映像経路 | 入力buffer・PTS・表示予定時刻・出力queue結果を結び付ける追加ログが得られない。 |
| 旧映像の所属世代 | 用意した世代→MediaSync buffer→SurfaceFlingerの対応付けに必要な中間証拠が欠ける。 |

パッチがあってもqueue成功は画面表示成功ではない。最終表示の判定には
SurfaceFlingerの記録と外部撮影が必要で、採取欠落時は断定しない。
採取コマンド・成立条件は[tvの統合手順](https://github.com/kazuki0824/tv/blob/fix/tis-scan-one-shot-close-and-restart-diagnostics-on-207/tis/INTEGRATION.md#黒画面停止不能旧映像の診断採取)
を正本とする。ビルドrevision・Framework差分・fingerprintと同じビルドの
symbolsも保持する。対象ABIのlibstagefrightとTISを両方更新し、既存Exact patchを
使う場合はその適用状態も記録する。採取scriptの`host-tv-revision.txt`はホスト
checkoutの記録であり、端末APKのrevision証明ではない。

## 確認範囲

ホストでのBash構文検査・パッチ適用確認は、Android製品ビルドや実機検証の
代替ではない。製品ビルド後、採取中に`PLAYBACK_SYNC_CREATE`・
`PLAYBACK_SYNC_INPUT`・`PLAYBACK_SYNC_OUTPUT`が現れることと、
対象layerのbuffer記録がtraceに存在することを確認する。
この統合だけで黒画面・停止不能・旧映像再表示の解消を保証しない。
