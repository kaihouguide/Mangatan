

# 🚀 Mangatan OCR Server - Installation Guide

Welcome! This guide provides the steps to get your Google Lens-powered OCR server running for a seamless reading experience.

---

## Choose Your Platform:

*   [**💻 For PC/Desktop**](#-for-pcdesktop)
*   [**📱 For Android**](#-for-android)

<br>

## <a id="for-pc-desktop"></a>💻 For PC/Desktop

### ✅ Step 1: Prerequisites

You'll need a few things before you start. Please install them in the following order.

1.  **Suwayomi-Server**
    *   First, download and set up the **[Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server)**.
    *   Follow the installation instructions provided on their official GitHub page to get it running.

2.  **Tampermonkey Extension & Userscript**
    *   Get the **[Tampermonkey](https://www.tampermonkey.net/)** extension for your browser.
    *   Then, install the required userscript for this project from this GitHub repository.

3.  **Node.js Environment**
    *   This provides the runtime (`node`) and package manager (`npm`) needed to run the OCR server.
    *   Please **[download and install Node.js](https://nodejs.org/en/download/)** first.
    *   You can verify if you have it by opening a terminal or command prompt and running:
        > ```sh
        > node -v
        > npm -v
        > ```

### 📦 Step 2: Get the OCR Server Source Code

1.  Download the OCR Server project files as a **ZIP** and unzip the folder.
2.  Open your terminal or Command Prompt and navigate into the unzipped OCR Server folder.

### ⚙️ Step 3: Install Dependencies & Configure

Now, from inside the project folder in your terminal:

1.  Run this command to install the necessary libraries:
    > ```sh
    > npm install express chrome-lens-ocr
    > ```
    > This command downloads both libraries into a `node_modules` folder, making them available to your script.

2.  Next, configure the `package.json` file:
    *   After the installation is finished, check if a `package.json` file was created.
    *   If it **was created**, open it and **replace its entire content** with the code block below.
    *   If it **was not created**, you must **make a new file** named `package.json` and paste the code block below into it.

    <details>
    <summary>Click to view package.json content</summary>

    ```json
    {
      "name": "my-ocr-server",
      "version": "1.0.0",
      "description": "",
      "main": "server.js",
      "type": "module",
      "scripts": {
        "test": "echo \"Error: no test specified\" && exit 1",
        "start": "node server.js"
      },
      "keywords": [],
      "author": "",
      "license": "ISC",
      "dependencies": {
        "express": "^4.17.1",
        "chrome-lens-ocr": "^1.0.6"
      }
    }
    ```
    </details>

### ▶️ Step 4: Start the Server

With all dependencies installed, you're ready to start the OCR server.

*   Run the following command in your terminal:
    > ```sh
    > node server.js
    > ```
    > **On Windows:** You can also run the `Runme.bat` file if it's available.

<br>

---

## <a id="for-android"></a>📱 For Android

For Android users, you'll need **Termux**.

> **Recommended Browser for Android:**
> For the best experience, it's recommended to use **Edge Canary**. After installing it, get the **Tampermonkey** extension.
>
> To install the userscript, go to Tampermonkey's Dashboard -> Utilities -> "Install from URL" and paste the link to the `.user.js` file from this repository.

1.  **Install Termux:**
    *   Download and install Termux from **[GitHub](https://github.com/termux/termux-app/releases)**.

2.  **Set up Suwayomi-Server in Termux:**
    *   Open a Termux session and run the following command to install and configure Suwayomi-Server. This sets up a simple `suwayomi` command for you to use.
    > ```sh
    > pkg update -y && pkg install -y openjdk-21 wget && mkdir -p ~/suwayomi/bin && wget -O ~/suwayomi/SuwayomiServer.jar https://github.com/Suwayomi/Suwayomi-Server/releases/download/v2.0.1727/Suwayomi-Server-v2.0.1727.jar && echo -e '#!/data/data/com.termux/files/usr/bin/bash\njava -jar ~/suwayomi/SuwayomiServer.jar' > ~/suwayomi/bin/suwayomi && chmod +x ~/suwayomi/bin/suwayomi && echo 'export PATH="$HOME/suwayomi/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
    > ```
    > From now on, you can always run Suwayomi by just typing `suwayomi` in Termux.

3.  **Set up Mangatan OCR Server in Termux:**
    *   In **another Termux session**, run the following command to download the server, install dependencies, and create a handy `mangatan` startup command.
    > ```sh
    > rm -rf ~/Mangatan && pkg install -y git nodejs && git clone https://github.com/kaihouguide/Mangatan && cd Mangatan/Ocr-Server && npm install express chrome-lens-ocr --ignore-scripts && npm install --cpu=wasm32 sharp && npm install --force @img/sharp-wasm32 && rm -rf node_modules/chrome-lens-ocr/node_modules/sharp && mkdir -p ~/bin && echo -e '#!/data/data/com.termux/files/usr/bin/sh\ncd ~/Mangatan/Ocr-Server && node server.js' > ~/bin/mangatan && chmod +x ~/bin/mangatan && echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc && source ~/.bashrc
    > ```
    > After this, you can always start the Mangatan server by just typing `mangatan` in Termux.

<br>

---

## 🎉 All Done!

Your server should now be active and ready to use. To stop it at any time, return to the terminal window and press **`Ctrl + C`**.

### DEMO
*(This entire project was tested kindly by **sonphamthai** on Discord, who also made the demo)*