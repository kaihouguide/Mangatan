### To make it easier to use this project we stared maintaing our own Language-learning Focused [suwayomi-fork](https://github.com/KolbyML/Mangatan) 
### have a suggetion or want to have a chat? Join [mangatan's discord server](https://discord.gg/tDAtpPN8KK)


## Please add \n to nothing in your yomitan replacement patterns under Translation for now
Welcome! This guide provides the steps to get your OCR server running for a seamless reading experience.

This project relies on [Suwayomi](https://github.com/Suwayomi/Suwayomi-Server) which is a free, open source, and cross-platform manga reader server that runs extensions built for Mihon (Tachiyomi).

With manga from Suwayomi, Mangatan will automatically make each pages' text scannable for Yomitan and other dictionary software.

## Choose Your Platform:
*   [**💻 Combined Server(Recommended)**](#combined-server) | Combines the below 2 methods into one easy to use script. 
*   [**💻 For PC/Desktop (Node.js)**](#for-pc-desktop) | The old method, still up-to-date and works just fine.
*   [**🐍 For PC - Local OCR (Alternative Python Server)**](#for-pc-local-ocr) | Locally run ocr server instead of google lens.
*   [**📱 For Android**](#for-android) | Host Mangatan and Suwayomi on your mobile device! 
*   [**📱 For Android Alternative**](#for-android-alternative) | Rely on a host server!



 There are multiple ways to run the OCR itself, the recommneded way is using the simplified combined server below.

## <a id="combined-server"></a>Combined Server

1.  **Suwayomi-Server**
    *   First, download and set up the **[Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server)**.
    *   Follow the installation instructions provided on their official GitHub page to get it running.

2.  **Tampermonkey Extension & Userscript**
    *   Get the **[Tampermonkey](https://www.tampermonkey.net/)** extension for your browser. ( allow access to file urls in your browser's extension settings)
    *   Then, install the required userscript for this project from this GitHub repository.

3. Install [uv](https://docs.astral.sh/uv/getting-started/installation/)
4. Run one of the following commands in the `ocr-server` folder:
    > ```
    > # Run with Google Lens ( Use Google to proccess )
    > uv run server.py
    >
    > # Run with OneOCR ( Use local computer to proccess ) 
    > uv run server.py -e=oneocr
    > ```


## 🎉 All Done!

Your ocr server should now be active and ready to use. To stop it at any time, return to the terminal window and press **`Ctrl + C`**.


### DEMO
*(This entire project was tested kindly by **sonphamthai** on Discord, Demo By Rin)*
![alt text](https://files.catbox.moe/xlxoja.gif)

## <a id="for-pc-desktop"></a>💻 For PC/Desktop (Node.js)

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

### 📦 Step 2: Get the OCR Server Legacy Source Code

1.  Download the `ocr-server-legacy` project files as a **ZIP** and unzip the folder.
2.  Open your terminal or Command Prompt and navigate into the unzipped `ocr-server-legacy` folder.
3.  ![showcase](https://raw.githubusercontent.com/kaihouguide/Mangatan/refs/heads/main/kaihouguide%20mangatan/For%20PC%20Desktop%20(Windows%E7%89%88)/Step%202%20Get%20the%20OCR%20Server%20Source%20Code/1.%20downloading%20ocr%20server.gif)

### ⚙️ Step 3: Install Dependencies & Configure

Now, from inside the `ocr-server-legacy` project folder in your terminal:

1.  Copy this command then paste (Ctrl+V) then press enter:
    > ```bash
    > npm ci
    > ```
    *   This command downloads all required libraries into a `node_modules` folder.


### ▶️ Step 4: Start the Server

With all dependencies installed, you're ready to start the server.

*   Run the following command in your terminal:
    > ```sh
    > node server.js
    > ```
*  **On Windows:** You can also run the `Runme.bat` file if it's available.

### 💡 Usage & New Features

*   **View Translations**: Simply move your mouse cursor over any image or manga panel. The OCR overlay will appear automatically.
*   **Focus on Text**: To make a specific text box clearer, just hover your mouse over it.
*   **Configuration**: Click the **`⚙️`** (gear) icon at the bottom-right to open the settings panel.
*   **Persistent Caching**: The server now automatically saves all OCR results to a file named `ocr-cache.json`. Your cache will be reloaded the next time you start the server.
*   **Cache Management**:
    *   **To Export**: Open a new browser tab to `http://127.0.0.1:3000/export-cache` to download your cache file.
    *   **To Import**: Use the settings panel in the userscript to upload a previously saved `ocr-cache.json` file.
*   **Anki Export**: After hovering on an image to make the overlay visible, a **`✚`** button will appear. Tapping this button will export a screenshot of the image to the last created card in Anki.


## <a id="for-pc-local-ocr"></a>🐍 For PC - Local OCR (Alternative Python Server)

This is a high-performance, alternative local OCR server written in Python. It does not require Node.js and processes images directly on your machine.

### ✅ Step 1: Prerequisites

*   You must have **Python** installed. You can download it from the official **[Python website](https://www.python.org/downloads/)**.
*   Ensure you have the Tampermonkey extension and the project's userscript installed in your browser, as described in the PC/Desktop section.
*   Install [OneOCR](https://github.com/AuroraWright/oneocr)

### ⚙️ Step 2: Install Dependencies

1.  Open your terminal or Command Prompt.
2.  Navigate into the `ocr-server-legacy` folder.
3.  Run the following command to install the required Python libraries:
    > ```sh
    > pip install oneocr waitress flask aiohttp Pillow "Flask[async]"
    > ```

### ▶️ Step 3: Start the Server

*   From the same terminal window, run the following command:
    > ```sh
    > python local_server.py
    > ```
*   The server will start on `http://127.0.0.1:3000`.
*   Optionally, run `runme(local-server).bat` 
### 💡 Usage

*   Once the server is running, make sure the **OCR Server URL** in the userscript settings (`⚙️` icon) is set to `http://127.0.0.1:3000`.
*   The server will automatically create and manage an `ocr-cache.json` file in its folder.



## <a id="for-android"></a>📱 For Android

For Android users, you'll need **Termux**.

> **Recommended Browser for Android:**
> For the best experience, it's recommended to use **Edge Canary** , **Firefox** or another browser that supports extensions. After installing it, install the **Tampermonkey** extension.
>
> To install the userscript, go to Tampermonkey's Dashboard -> Utilities -> "Install from File" after you download from this repository, or simply copy-paste the code.

1.  **Install Termux:**
    *   Download and install Termux from **[F-Droid](https://f-droid.org/en/packages/com.termux/)** or **[GitHub](https://github.com/termux/termux-app/releases)**.

2.  **Set up Suwayomi-Server in Termux:**
    *   Open a Termux session and run the following command to install and configure Suwayomi-Server. This sets up a simple `suwayomi` command for you to use.
    > ```sh
    > pkg update -y && pkg install -y openjdk-21 wget jq libandroid-posix-semaphore && mkdir -p ~/suwayomi/bin && LATEST_JAR_URL=$(curl -s https://api.github.com/repos/Suwayomi/Suwayomi-Server/releases/latest | jq -r '.assets[] | select(.name | endswith(".jar")) | .browser_download_url') && wget -O ~/suwayomi/SuwayomiServer.jar "$LATEST_JAR_URL" && echo -e '#!/data/data/com.termux/files/usr/bin/bash\njava -jar ~/suwayomi/SuwayomiServer.jar' > ~/suwayomi/bin/suwayomi && chmod +x ~/suwayomi/bin/suwayomi && echo 'export PATH="$HOME/suwayomi/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
    > ```
    *   From now on, you can always run Suwayomi by just typing `suwayomi` in Termux.

3.  **Set up Mangatan OCR Server in Termux:**
    *   In **another Termux session**, run the single command below. It has been revised to be more stable and will download the server, install all dependencies by correctly forcing the platform compatibility for Termux, and create a handy `mangatan` startup command.
    *   Copy the entire command block and paste it into your Termux terminal, then press Enter.
    > ```sh
    > rm -rf ~/Mangatan && pkg install -y git nodejs && git clone https://github.com/kaihouguide/Mangatan && cd Mangatan/ocr-server-legacy && npm install express chrome-lens-ocr multer node-fetch --force && mkdir -p ~/bin && echo -e '#!/data/data/com.termux/files/usr/bin/sh\ncd ~/Mangatan/ocr-server-legacy && node server.js' > ~/bin/mangatan && chmod +x ~/bin/mangatan && echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc && source ~/.bashrc
    
      *   After the command above finishes, run these next commands **one-by-one** to finalize the installation.
    > ```sh
    > npm install --cpu=wasm32 sharp --force
    > ```
    > ```sh
    > npm install @img/sharp-wasm32 --force
    > ```
    > ```sh
    > rm -rf node_modules package-lock.json
    > ```
    > ```sh
    > npm install --force
    > ```
After this, you can always start the Mangatan server by just typing `mangatan` in Termux.

### 💡 Usage
*   Open Termux and write `suwayomi`, swipe from left to right to open a new session*, and write `mangatan`. Then go to `127.0.0.1:4567` and start reading. *If you have swipe gestures, swipe from bottom left, upwards.
*   **Toggle Overlay**: **Long-press** (press and hold for about half a second) on an image to show or hide the OCR text overlay.
*   **Tap-to-Focus**: Once the overlay is visible, **tap** on any specific text box to highlight it.
*   **Configuration**: Tap the **`⚙️`** (gear) icon to open the settings panel. From here you can change the color theme, text orientation, Anki settings, and more.
*   **Anki Export**: After long-pressing an image to make the overlay visible, a **`✚`** button will appear. Tapping this button will export a screenshot of the image to the last created card in Anki.
*   **Note**: The persistent cache file (`ocr-cache.json`) will be stored in the `~/Mangatan/ocr-server-legacy` directory.

Here is the updated response with the new header you requested.

## <a id="for-android-alternative"></a>📱 For Android {ALTERNATIVE}

This section provides an alternative setup method for users who prefer to run the servers on a desktop or host machine and access them from their mobile device.

1.  **Download and Set up Suwayomi & OCR on Host Machine:**

      * Begin by downloading and configuring both the Suwayomi-Server and Mangatan OCR-Server on your host computer (Windows, macOS, or Linux).

2.  **Configure Suwayomi and OCR URLs:**

      * **Suwayomi Setup**:

          * Locate the `server.conf` file, which is typically found in the application data directory.
          * Change the `server.ip` setting to your host machine's IP address. More information on the default data directory locations can be found below.

        > **Data Directory Locations:**

        >   * **Windows 7 and later**: `C:\Users\<Account>\AppData\Local\Tachidesk`
        >   * **Windows XP**: `C:\Documents and Settings\<Account>\Application Data\Local Settings\Tachidesk`
        >   * **macOS**: `/Users/<Account>/Library/Application Support/Tachidesk`
        >   * **Unix/Linux**: `/home/<account>/.local/share/Tachidesk`

      * **OCR Setup**:

          * Launch the Mangatan OCR server with a custom argument to specify its IP address.
          * Use the command-line argument `--ip <your_host_ip_address>` when starting the server.

3.  **Mobile Setup:**

      * On your Android device, install the **Tampermonkey** extension on your preferred browser (e.g., Edge Canary, Firefox).
      * Install the tampermonkey and the script from the repository.
      * After installation, adjust the IP addresses and port numbers in the scripts's settings to match the ones you configured on your host machine. This will allow your mobile browser to connect to the servers running on your desktop. (You will have to do this every script update——For now.)

### 💡 Tips

  * **Automate Startup**: For the most reliable performance, you should run the Suwayomi server and the OCR server as separate services. This allows a tool like **NSSM** (Non-Sucking Service Manager) to monitor and restart each component independently if it crashes.

  * **Example Script for Suwayomi Server**:
    To launch the core server directly and avoid any issues with the launcher, create a `.bat` file with the following content. Make sure to use the specific Java runtime that comes with the application.

    ```bat
    @echo off
    cd /d "<path-to-suwayomi-server-folder>"
    "<path-to-suwayomi-server-folder>\jre\bin\java.exe" -jar "<path-to-suwayomi-server-folder>\bin\Suwayomi-Server.jar"
    ```

  * **Example Script for OCR Server**:
    The OCR server should be in a separate `.bat` file and configured as its own service.

    ```bat
    @echo offs
    cd /d "<path-to-suwayomi-server-folder>\ocr-server-legacy"
    node server.js --cache-path "<your-cache-path>" --ip <your-ip-address> --port <your-port>
    ```

  * **Important**: You must use absolute paths for both the `cd` commands and the executable files. NSSM services often run with a different environment than your user account, so relative paths may not work correctly.
#### Notes

* You will have to go into tampermonkey and change each value of 127.0.0.1 to your host IP, this will have to be repeated every time you update your script! 





