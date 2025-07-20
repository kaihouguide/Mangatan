# Mangatan

This UserScript enhances your web browsing by automatically performing Optical Character Recognition (OCR) on images, using Google's powerful Gemini models. It's designed for reading comics and manga online, intelligently pre-loading text data and overlaying it directly onto the images. Its standout feature is the ability to use multiple API keys, automatically switching to a backup if one gets rate-limited.

### Core Features:

*   **High-Quality OCR**: Utilizes `gemini-2.5-flash` and `gemini-2.5-pro` for accurate text extraction, including vertical text and Japanese furigana.
*   **Smart Pre-loading**: A "lookahead" system processes upcoming images before you scroll to them, ensuring a seamless reading experience.
*   **Fallback API Keys**: Add multiple Gemini API keys. The script automatically cycles to the next key if one fails or gets rate-limited.
*   **Site-Agnostic**: Easily configurable to run on any website by specifying a URL pattern and a CSS selector for the image container.
*   **Interactive Text Overlays**: Hover over an image to see the detected text displayed in its original position and orientation.
*   **Simple UI**: A clean settings panel allows you to manage API keys, select a model, and configure site-specific rules.

### Quick Setup:

1.  **Install a UserScript Manager**: Use an extension like [Tampermonkey](https://www.tampermonkey.net/) or [Violentmonkey](https://violentmonkey.github.io/).
2.  **Get a Gemini API Key**: Obtain one from [Google AI Studio](https://aistudio.google.com/prompts/new_chat).
3.  **Install the Script**: Install from the source link.
4.  **Configure**: Click the **⚙️** icon on any webpage to open the settings. Paste your API key(s), adjust the settings to your liking, and click **Save and Reload**.

Once configured, the script will run automatically on the sites you've specified. Just hover over an image to see the OCR results.
      
![Demo of OCR Script]((https://files.catbox.moe/71uro7.mp4))

    
