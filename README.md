Of course. You are absolutely right—some of the blockquotes and lists could be rendered more cleanly and consistently. I have revised the guide to fix these Markdown errors, ensuring it looks sharp and professional on GitHub.

The core instructions and wording remain identical.

---

# 🚀 **Mangatan OCR Server - Installation Guide**

Welcome! This guide provides the steps to get your private OCR server running.

---

## ✅ **Step 1: Prerequisites**

You will need a few things before you start. Please install them in the following order.

1.  **Suwayomi-Server**
    - First, download and set up the **[Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server)**.
    - Follow the installation instructions provided on their official GitHub page to get it running.

2.  **Tampermonkey Extension & Userscript**
    - Get the [Tampermonkey extension for your browser](https://www.tampermonkey.net/).
    - Then, install the required userscript for this project from this GitHub repository.

3.  **Node.js Environment**
    - This provides the runtime (`node`) and package manager (`npm`) needed to run the OCR server.
    - You can verify if you have it by opening a terminal or command prompt and running:
      ```bash
      node -v
      npm -v
      ```
    - If these commands return version numbers (e.g., `v18.17.1`), you are ready. If not, please [download and install the "LTS" version of Node.js](https://nodejs.org/en/download/) first.

---

## 📦 **Step 2: Get the OCR Server Source Code**

1.  Download the OCR Server project files as a **ZIP** and unzip the folder.
2.  Open your terminal or Command Prompt and **navigate into the unzipped OCR Server folder**.

---

## ⚙️ **Step 3: Install Dependencies & Configure**

Now, from inside the project folder in your terminal:

1.  **Run this command** to install the necessary libraries:
    ```bash
    npm install express chrome-lens-ocr
    ```
    > *This command downloads both libraries into a `node_modules` folder, making them available to your script.*

2.  **Next, configure the `package.json` file:**
    - After the installation is finished, check if a `package.json` file was created.
    - If it **was created**, open it and **replace its entire content** with the code block below.
    - If it **was not created**, you must **make a new file named `package.json`** and paste the code block below into it.

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

---

## ▶️ **Step 4: Start the Server**

With all dependencies installed, you are ready to start the OCR server.

Run the following command in your terminal:
```bash
node server.js
```
> **On Windows:** You can also run the `Runme.bat` file if it is available.

<br>

### 🎉 **All Done!**

Your server should now be active and ready to use. To stop it at any time, return to the terminal window and press `Ctrl + C`.
