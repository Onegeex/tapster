import sys, asyncio
from playwright.async_api import async_playwright
async def main(pairs):
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"])
        pg = await b.new_page(viewport={"width":1280,"height":900})
        for url,out in pairs:
            await pg.goto(url, wait_until="networkidle")
            await pg.screenshot(path=out, full_page=True)
        await b.close()
args=sys.argv[1:]
asyncio.run(main(list(zip(args[0::2],args[1::2]))))
