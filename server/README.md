
# （開発用）設定ファイルのコピー
```bash
./setting_deploy.sh
```

# （開発用）ビルド＆ファイル配置
```bash
./clean_build_deploy.sh
```


# サーバーの起動方法

```bash
node http-server.js
```

# メッセージテスト送信
```bash
curl -X POST -d 'Hello, World!' http://localhost:3000
```

# サーバーのデプロイ
```bash
cd server
./clean_build_deploy.sh
```
app-mac/echo/Resources/server.zip に server(nodejs) を圧縮して配置します。




## AivisSpeech が必要です 📢

本アプリは **音声合成エンジン AivisSpeech**（無料）を前提に動作します。  
あらかじめご自身でインストール＆モデル準備をお願いします。

### インストール手順

1. **AivisSpeech の本体をダウンロード**  
   公式サイト → <https://aivis-project.com/download/>

2. **音声モデルをダウンロード**  
   - AivisSpeech 初回起動時、または AivisHub (<https://hub.aivis-project.com/>) から  
     好みの声質モデル（.aivm）を入手し、AivisSpeech に追加してください。  
   - モデルがないと音声が生成されません。

> 🔧 AivisSpeech は本アプリ起動時に自動でバックグラウンド起動します。  
>  手動で「エンジンを起動」する必要はありません。

---

### ライセンスと免責

- **音声モデルごとにライセンス条件が異なります**（商用可否・二次配布可否 など）。  
- 最新のライセンスは各モデルの AivisHub ページで確認してください。  
- **当プロジェクトはライセンス内容の追跡・保証を行いません。ご利用は自己責任でお願いします。**

### 商標

*AivisSpeech は Walkers Inc. の商標です。*  
ロゴ・名称の利用規程は公式ガイドラインを参照してください。
