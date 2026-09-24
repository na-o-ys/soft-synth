# soft-synth

MIDI 鍵盤をつなぐだけで、やわらかいシンセ音が鳴る常駐デーモン（macOS）。
GarageBand を起動せずに弾きたいとき用。

- サイン波ベースの加算合成 + 軽い FDN リバーブ（耳当たり重視）
- 32 音ポリフォニー、サステインペダル（CC64）対応
- 鍵盤の抜き差し・出力デバイス切替に自動追従
- 待機時 CPU 約 0.5%、メモリ約 6MB

## 使い方

```sh
make demo       # 鍵盤なしで和音を鳴らして確認
make install    # ~/.local/bin に入れて LaunchAgent 登録（ログイン時に自動起動）
make log        # ログを見る
make restart    # 再起動
make uninstall  # 削除
```

音色は `Sources/main.swift` の `Synth` 冒頭の係数（減衰・リリース・倍音量・`masterGain`）で調整する。
