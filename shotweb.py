import asyncio, sys
from playwright.async_api import async_playwright
U="http://localhost:8090/?ns=tapsterns&rpc=http://localhost:26657&chain=dev&web=http://localhost:8888"
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"])
        pg = await b.new_page(viewport={"width":1280,"height":900})
        errs=[]; pg.on("console", lambda m: errs.append(m.text) if m.type=="error" else None)
        await pg.goto(U, wait_until="networkidle"); await pg.wait_for_timeout(2500)
        await pg.screenshot(path="shots/web-feeds.png", full_page=True)
        for v in ["reporters","tab","activity","integrate"]:
            await pg.click(f'#tabs button[data-v="{v}"]'); await pg.wait_for_timeout(400)
            await pg.screenshot(path=f"shots/web-{v}.png", full_page=True)
        await pg.goto("http://localhost:8090/?ns=nope&rpc=http://localhost:26657", wait_until="networkidle"); await pg.wait_for_timeout(1500)
        await pg.screenshot(path="shots/web-demo.png", full_page=False)
        print("console errors:", errs[:5])
        await b.close()
asyncio.run(main())
