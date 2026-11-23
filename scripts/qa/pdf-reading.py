"""Exercise the packaged app using the hosted Mac's keyboard, mouse and display."""
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess as sp
import sys
import time
from difflib import SequenceMatcher
from statistics import median

if os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or sys.platform != "darwin":
    raise SystemExit("This driver requires a disposable GitHub-hosted macOS desktop.")

import Quartz
import pymupdf as fitz
import pyautogui as ui
import pytesseract as ocr
from PIL import Image, ImageChops, ImageDraw

app = Path(sys.argv[1]).resolve()
url = "https://arxiv.org/pdf/" + sys.argv[2]
out = Path(os.environ["RUNNER_TEMP"]) / "pdf-reading"
out.mkdir()
db = Path.home() / "Library/Application Support/Margin/library.sqlite"
w, h = ui.size()
processes = []
stage = "setup"


def phase(name):
    global stage
    stage = name
    print(name, flush=True)
    with (out / "phases.txt").open("a") as log:
        print(time.strftime("%H:%M:%S"), name, file=log)


def screen(label=None):
    image = ui.screenshot().convert("RGB")
    if image.size != (w, h):
        image = image.resize((w, h), Image.Resampling.LANCZOS)
    if label:
        image.save(out / (label + ".png"))
    return image


def words(image, box=None, mode=11):
    left, top, right, bottom = box or (0, 0, w, h)
    data = ocr.image_to_data(image.crop((left, top, right, bottom)).resize(
        (2 * (right-left), 2 * (bottom-top))), config=f"--psm {mode}", output_type=ocr.Output.DICT)
    result = []
    for i, text in enumerate(data["text"]):
        if text.strip():
            x = left + data["left"][i] / 2
            y = top + data["top"][i] / 2
            result.append((text, x, y, x + data["width"][i]/2, y + data["height"][i]/2))
    return result


def norm(text):
    return re.sub(r'[^a-z0-9]', '', text.lower())


def allow_chrome_prompt():
    # The real app asks macOS for Automation consent on this fresh test account.
    image = screen()
    # Locate the positive blue button in the centered macOS consent sheet.
    x = w//2 + 35
    start = None
    for y in range(140, h//2+120):
        r,g,b = image.getpixel((x,y))
        if r < 35 and 70 < g < 170 and b > 210:
            if start is None:
                start = y
        elif start is not None:
            if 20 <= y-start <= 35:
                box = (w//2-122,start-140,w//2+122,start-4)
                entries = words(image, box, mode=6)
                message = norm(" ".join(entry[0] for entry in entries))
                actors = ("margin", "hostedcomputeagent")
                if ("controlgooglechrome" in message
                        and any(actor+"wantsaccess" in message for actor in actors)):
                    image.save(out/"chrome-automation-consent.png")
                    ui.click(x, (start+y)//2)
                    print("Granted the hosted reading session Chrome Automation", flush=True)
                    time.sleep(.6)
                    return
            start = None


def wait(check, seconds=25):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        allow_chrome_prompt()
        result = check()
        if result:
            return result
        time.sleep(.55)
    raise AssertionError("Timeout at " + stage)


def rows(query):
    if not db.exists():
        return []
    with sqlite3.connect(db.as_uri() + "?mode=ro", uri=True) as conn:
        return conn.execute(query).fetchall()


def margin_shortcut(key):
    control = Quartz.kCGEventFlagMaskControl
    shift = Quartz.kCGEventFlagMaskShift
    key_code = {"s": 1, "n": 45, "h": 4}[key]
    state = Quartz.kCGEventSourceStateHIDSystemState
    source = Quartz.CGEventSourceCreate(state)
    for code,down,flags in [(59,True,control),(56,True,control|shift),(key_code,True,control|shift),
                            (key_code,False,control|shift),(56,False,control),(59,False,0)]:
        event = Quartz.CGEventCreateKeyboardEvent(source,code,down)
        if code in (56,59):
            Quartz.CGEventSetType(event,Quartz.kCGEventFlagsChanged)
        Quartz.CGEventSetFlags(event, flags)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap,event)
        time.sleep(.055)


def launch_app():
    process = sp.Popen([str(app / "Contents/MacOS/Margin")], stderr=app_log, stdout=app_log)
    processes.append(process)
    time.sleep(1)
    assert process.poll() is None, "Packaged app exited during startup"
    return process


def address(target):
    ui.hotkey("command", "l")
    # Paste the URL so the active keyboard layout cannot alter its punctuation.
    sp.run(["pbcopy"], input=target, text=True, check=True)
    ui.hotkey("command", "v")
    ui.press("enter")
    time.sleep(3)


def check_tab_url(expected):
    sp.run(["pbcopy"],input="",text=True,check=True)
    ui.hotkey("command","l")
    ui.hotkey("command","c")
    time.sleep(.15)
    actual = sp.check_output(["pbpaste"],text=True).strip()
    ui.press("escape")
    assert actual == expected, f"Expected Chrome tab {expected!r}, read {actual!r}"


def displayed_page():
    button = toolbar_zoom(button=True)
    if not button:
        return None
    x,y = (round(button[0]-173),round(button[1]))
    digits = screen().crop((x-11,y-11,x+12,y+10)).resize((92,84))
    text = ocr.image_to_string(digits,config="--psm 7 -c tessedit_char_whitelist=0123456789").strip()
    return int(text) if text.isdigit() else None


def body():
    return (max(280, int(.27*w)), 175, w-30, h-38)


def toolbar_zoom(button=False):
    box = (w//4, 85, 3*w//4, 175)
    for value, x, y, right, bottom in words(screen(), box):
        match = re.search(r"(\d{2,3})%", value)
        if match:
            return ((x+right)/2 + 45, (y+bottom)/2) if button else int(match[1])
    return None


def select_line(exclude_page=None):
    image = screen()
    tokens = words(image, body())
    attempts = 0
    for i, first in enumerate(tokens):
        if not re.fullmatch("[A-Za-z]{3,}", first[0]) or first[2] > h-(205 if exclude_page else 100):
            continue
        line = [first]
        for item in tokens[i+1:i+6]:
            if abs(item[2]-first[2]) > 4 or not 0 <= item[1]-line[-1][3] <= 16:
                break
            line.append(item)
        if len(line) < 4:
            continue
        if exclude_page:
            snippets = [norm(" ".join(v[0] for v in line[j:j+3])) for j in range(len(line)-2)]
            if not any(k not in pages[exclude_page-1] and any(k in page for page in pages)
                       for k in snippets):
                continue
        attempts += 1
        if attempts > 8:
            break
        last = line[-1]
        mid = (first[2]+first[4])/2
        ui.moveTo(first[1]-1, mid)
        ui.dragTo(last[3]+1, mid, .4, button="left")
        sp.run(["pbcopy"], input="", text=True, check=True)
        ui.hotkey("command", "c")
        time.sleep(.15)
        quote = sp.check_output(["pbpaste"], text=True).strip()
        key = norm(quote)
        matches = [n for n, page in enumerate(pages, 1) if key in page]
        if (len(key) >= 14 and len(matches) == 1 and pages[matches[0]-1].count(key) == 1
                and matches[0] != exclude_page and norm(line[1][0]) in key):
            return quote, matches[0], (int(first[1]-3), int(first[2]-4), int(last[3]+4), int(last[4]+4)), image
    return None


def yellow(image, box):
    # Margin's translucent yellow over white paper renders at (255,255,153).
    # SmolVLA includes a pale yellow abstract box in its original artwork.
    return sum(r >= 248 and g >= 248 and 145 <= b <= 165 for r,g,b in image.crop(box).getdata())


def save_mark(name, selection):
    quote, page, box, before = selection
    phase(f"save {name} on page {page}: {quote!r}")
    screen(name+"-selected")
    margin_shortcut("s")
    wait(lambda: any(norm(q) == norm(quote) and doc.split("#")[0] == "url:"+url.replace("/pdf/","/abs/") for q, doc in
                     rows("select quote,document_id from highlights")))
    ui.click(box[0], min(h-25, box[3]+12))
    phase("verify cleared selection and visible " + name)
    baseline = yellow(before, box)
    wait(lambda: yellow(screen(), box) > baseline + max(55, (box[2]-box[0])*2), 45)
    screen(name+"-visible")
    check_tab_url(url)
    return page


def visible(text, box=None):
    return norm(text) in norm(" ".join(t[0] for t in words(screen(), box)))


def click_label(label):
    entries = words(screen(), (max(0,w-455), 30, w, min(h,350)))
    for text,x,y,r,b in entries:
        if norm(text) == norm(label):
            ui.click((x+r)/2,(y+b)/2)
            return True
    return False


def paper_frame(selection, zoom):
    quote, number, box, _ = selection
    with fitz.open(out.parent/"paper.pdf") as document:
        page = document[number-1]
        hits = page.search_for(quote)
        assert len(hits) == 1, f"Cannot locate selected single line on paper: {quote!r}"
        line = hits[0]
        scale = zoom * 96 / 7200
        left = box[0]+3 - line.x0*scale
        top = (box[1]+box[3])/2 - (line.y0+line.y1)*scale/2
        return (left, top, left+page.rect.width*scale, top+page.rect.height*scale, scale)


def reopened_frame(entries, number, zoom):
    # Register a fresh screenshot against printed paper words. Each pair offers
    # an independent estimate of the page's top-left corner at the current zoom.
    scale = zoom * 96 / 7200
    with fitz.open(out.parent/"paper.pdf") as document:
        page = document[number-1]
        source = {}
        for x,y,r,b,word,*_ in page.get_text("words"):
            key = norm(word)
            source[key] = None if key in source else ((x+r)/2,(y+b)/2,r-x)
        shifts = []
        for word,x,y,r,b in entries:
            key = norm(word)
            match = source.get(key)
            if match and len(key)>=4 and abs((r-x)-match[2]*scale) <= 6:
                shifts.append(((x+r)/2-match[0]*scale,(y+b)/2-match[1]*scale))
        if len(shifts)<3:
            return None
        mx,my = map(median,zip(*shifts))
        aligned = [(x,y) for x,y in shifts if abs(x-mx)<=6 and abs(y-my)<=6]
        if len(aligned)<3:
            return None
        left,top = map(median,zip(*aligned))
        return (left,top,left+page.rect.width*scale,top+page.rect.height*scale,scale)


def restored_quote(image, quote, number, frame):
    with fitz.open(out.parent/"paper.pdf") as document:
        page = document[number-1]
        matches = page.search_for(quote)
        if len(matches) != 1:
            return False
        target = matches[0]
        printed = [fitz.Rect(*word[:4]) for word in page.get_text("words")
                   if target.contains(fitz.Point((word[0]+word[2])/2,(word[1]+word[3])/2))]
    left,top,_,_,scale = frame
    def bounds(rect):
        return tuple(round(value) for value in (left+rect.x0*scale,top+rect.y0*scale,
                                                 left+rect.x1*scale,top+rect.y1*scale))
    if not printed or any(yellow(image,bounds(word)) < 8 for word in printed):
        return False
    x,y,r,b = bounds(target)
    # The green channel removes the yellow background while preserving black and red ink.
    crop = image.crop((x-2,y-2,r+2,b+2)).getchannel("G")
    text = ocr.image_to_string(crop.resize((crop.width*3,crop.height*3)),config="--psm 7")
    return SequenceMatcher(None,norm(text),norm(quote)).ratio() >= .85


def sticky_corner(point, frame):
    x,y = point
    left,top,right,bottom,scale = frame
    return (max(left,min(x,right-160*scale)), max(top,min(y,bottom-26*scale)))


def note_position(image, message, expected):
    x, y = expected
    if not (0 <= x < w-40 and 172 <= y < h-40):
        return False
    # Find the connected yellow rectangle first, so nearby printed words cannot
    # enter the OCR sample. A short note has a single line of black text.
    red, green, blue = image.split()
    mask = Image.eval(red, lambda n: 255 if n>238 else 0)
    mask = ImageChops.multiply(mask, Image.eval(green, lambda n: 255 if 222<n<252 else 0))
    mask = ImageChops.multiply(mask, Image.eval(blue, lambda n: 255 if 145<n<191 else 0))
    for dx,dy in ((13,12),(20,8),(10,15)):
        seed = (round(x+dx),round(y+dy))
        if mask.getpixel(seed) != 255:
            continue
        ImageDraw.floodfill(mask, seed, 128)
        box = mask.point(lambda n: 255 if n==128 else 0).getbbox()
        if box and abs(x-box[0]) <= 10 and abs(y-box[1]) <= 10:
            note = image.crop(box).getchannel("G")
            text = ocr.image_to_string(note.resize((note.width*3,note.height*3)),config="--psm 7")
            if norm(text) == norm(message):
                print("Note",message,"click-adjusted expected",expected,"visible bounds",box,flush=True)
                return True
        break
    return False


def sticky(name, point, page, frame):
    phase("open sticky editor on " + name)
    ui.moveTo(*point)
    margin_shortcut("n")
    wait(lambda: visible("Sticky note"))
    message = name + " memo"
    ui.write(message, .04)
    screen(name+"-editor")
    ui.hotkey("command","enter")
    phase("verify saved sticky at pointer: " + message)
    def stored():
        for value, anchor, source in rows("select text,anchor_json,url from sticky_notes"):
            if value == message and url == source.split("#")[0] and json.loads(anchor).get("page") == page:
                return True
        return False
    wait(stored)
    expected = sticky_corner(point, frame)
    wait(lambda: note_position(screen(), message, expected), 45)
    screen(name+"-visible")
    check_tab_url(url)
    return message


def blank_point(image, text_point, frame, mark):
    left, top, right, bottom, scale = frame
    for y in range(max(215,int(top)+15), min(h-65,int(bottom-28*scale)), 12):
        for x in range(max(body()[0]+25,int(left)+25), min(w-75,int(right)-40), 12):
            if abs(y-text_point[1]) < 65 or mark[1]-45*scale < y < mark[3]+10:
                continue
            area = image.crop((x-14,y-8,x+24,y+12))
            if all(lo > 247 for lo,hi in area.getextrema()):
                return x,y
    raise AssertionError("No white paper patch visible")


def sidebar(quotes, notes, page):
    phase("verify library filters in the sidebar")
    margin_shortcut("h")
    wait(lambda: click_label("Highlights"))
    sidebar_box = (max(0,w-455), 75, w, h)
    for quote in quotes:
        wait(lambda: visible(" ".join(quote.split()[1:4]), sidebar_box))
    screen("sidebar-highlights")
    wait(lambda: click_label("Notes"))
    for note in notes:
        wait(lambda: visible(note, sidebar_box))
    wait(lambda: visible(f"Page {page}", sidebar_box))
    screen("sidebar-notes")
    margin_shortcut("h")


def run():
    global pages
    paper = out.parent / "paper.pdf"
    sp.run(["curl","-fLsS","--retry","3","--max-time","60",url,"-o",str(paper)],check=True)
    with fitz.open(paper) as doc:
        pages = [norm(page.get_text()) for page in doc]
    profile = out.parent / "margin-reading-profile"
    (profile / "Default").mkdir(parents=True)
    (profile / "Default/Preferences").write_text(json.dumps({"browser":{"allow_javascript_apple_events":True}}))
    processes.append(sp.Popen(["/usr/bin/log","stream","--style","compact","--level","debug",
                               "--predicate",'subsystem == "com.jackboylan.margin"'],
                              stdout=diagnostics, stderr=diagnostics))
    margin = launch_app()
    phase("dismiss first-launch settings")
    screen("first-launch")
    # The gear returns from Settings to the library. Close via the registered shortcut.
    settings = wait(lambda: next((entry for entry in words(screen(), (w-450,25,w,135))
                                 if norm(entry[0]) == "settings"), None))
    ui.click(w-87, (settings[2]+settings[4])/2)
    wait(lambda: visible("Highlights", (w-450,30,w,250)))
    ui.click(w-50, (settings[2]+settings[4])/2)
    chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    pdf_options = ["--disable-features=PdfInk2"] if sys.argv[2] == "1706.03762" else []
    print("Chrome PDF options:", pdf_options, flush=True)
    processes.append(sp.Popen([chrome, *pdf_options, "--user-data-dir="+str(profile),"--no-first-run",
                               "--no-default-browser-check","--start-maximized","--use-mock-keychain",
                               url],stdout=app_log,stderr=app_log))
    phase("select first passage at Chrome's default PDF zoom")
    time.sleep(4)
    first = wait(select_line)
    first_page = save_mark("first", first)
    phase("scroll away and back to the first saved highlight")
    first_box = first[2]
    ui.moveTo((first_box[0]+first_box[2])/2,(first_box[1]+first_box[3])/2)
    painted = yellow(screen(), first_box)
    ui.scroll(-4)
    wait(lambda: yellow(screen(), first_box) < painted/2)
    screen("scrolled-away")
    ui.hotkey("command","home")
    ui.scroll(12)
    wait(lambda: yellow(screen(), first_box) > painted*.75)
    screen("scrolled-back")
    phase("zoom and scroll to another page")
    ui.moveTo(*first[2][:2])
    original_zoom = wait(toolbar_zoom)
    ui.click(*wait(lambda: toolbar_zoom(button=True)))
    wait(lambda: (value := toolbar_zoom()) and value != original_zoom)
    zoom = toolbar_zoom()
    print("PDF zoom", original_zoom, "->", zoom, flush=True)
    # Page and zoom inputs share a toolbar group. Navigate through the visible
    # page field, then validate the new passage against the original PDF pages.
    plus_x,toolbar_y = wait(lambda: toolbar_zoom(button=True))
    ui.click(plus_x-173,toolbar_y)
    ui.hotkey("command","a")
    ui.write(str(first_page+1))
    ui.press("enter")
    time.sleep(1)
    screen("next-page")
    ui.click(w*.69,h*.65)
    second = None
    for _ in range(3):
        second = select_line(first_page)
        if second:
            break
        ui.moveTo(w*.7,h*.65)
        ui.scroll(-5)
        time.sleep(.7)
    assert second, "No selectable passage from another PDF page"
    second_page = save_mark("second", second)
    phase("find text and whitespace note locations")
    frame = paper_frame(second, zoom)
    left, top, right, bottom, scale = frame
    entries = words(screen(), body())
    text = next(((int((x+r)/2),int((y+b)/2)) for token,x,y,r,b in entries
                 if token.isalpha() and len(token)>3 and y > second[2][3]+25
                 and max(top+5,175) < y < min(bottom-50*scale,h-80)
                 and left+15 < x < min(w-85,right-170*scale)), None)
    assert text, "No second printed line visible for text sticky"
    blank = blank_point(screen(), text, frame, second[2])
    notes = [sticky("Text", text, second_page, frame), sticky("Whitespace", blank, second_page, frame)]
    note_points = {name: ((x-left)/scale,(y-top)/scale)
                   for name,(x,y) in zip(notes,(text,blank))}
    sidebar([first[0], second[0]], notes, second_page)
    phase("restart packaged Margin and reopen the paper in a fresh Chrome tab")
    margin.terminate()
    margin.wait(timeout=10)
    launch_app()
    ui.hotkey("command","t")
    address("about:blank")
    ui.hotkey("ctrl","shift","tab")
    ui.hotkey("command","w")
    # The original tab was just closed. A fresh navigation starts the PDF viewer.
    time.sleep(.7)
    check_tab_url("about:blank")
    for number, selection in [(first_page, first), (second_page, second)]:
        if number == second_page:
            ui.hotkey("command","t")
        target = url+f"#page={number}"
        address(target)
        check_tab_url(target)
        wait(lambda: displayed_page() == number)
        phase(f"verify restored marks on page {number}")
        def viewport():
            image = screen()
            entries = words(image, body())
            level = toolbar_zoom()
            frame = reopened_frame(entries,number,level) if level else None
            return (image,entries,frame) if frame else None

        initial, _, origin = wait(viewport)
        initial.save(out/f"reopen-page-{number}-initial.png")
        def painted_view():
            state = viewport()
            if state and restored_quote(state[0], selection[0], number, state[2]):
                return state
            return None

        # Let Chrome restore paint with the reader stationary. Scrolling while
        # Margin registers the new viewer would cancel the position measurement.
        image, _, restored = wait(painted_view, 55)
        assert max(abs(restored[i]-origin[i]) for i in (0,1)) <= 5, "Page shifted during restoration"
        image.save(out/f"reopened-page-{number}.png")
        check_tab_url(target)
        if number == second_page:
            remaining = dict(note_points)
            for _ in range(6):
                for note,(px,py) in list(remaining.items()):
                    click = (restored[0]+px*restored[4], restored[1]+py*restored[4])
                    if note_position(image,note,sticky_corner(click,restored)):
                        image.save(out/f"reopened-{note.split()[0]}.png")
                        del remaining[note]
                if not remaining:
                    break
                ui.moveTo(w*.7,h*.65)
                ui.scroll(-2)
                time.sleep(.6)
                image,_,restored = wait(viewport)
            assert not remaining, f"Missing or moved restored notes: {list(remaining)}"
    phase("passed")


with (out / "process.log").open("w") as app_log, (out / "margin.log").open("w") as diagnostics:
    try:
        run()
    except BaseException:
        screen("failure")
        (out / "failure.txt").write_text(stage+"\n"+ocr.image_to_string(screen()))
        raise
    finally:
        if db.exists():
            with sqlite3.connect(db) as src, sqlite3.connect(out/"library.sqlite") as dest:
                src.backup(dest)
        for proc in reversed(processes):
            if proc.poll() is None:
                proc.terminate()
