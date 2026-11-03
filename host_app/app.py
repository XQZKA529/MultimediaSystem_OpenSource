"""FPGA media desktop manager. Run: python host_app/app.py"""
import json
import queue
import shutil
import tempfile
import threading
import sys

# Opt into system DPI awareness before Tcl/Tk creates windows. Windows scales
# the window if it moves to a monitor with a different DPI.
if sys.platform == 'win32':
    try:
        import ctypes
        ctypes.windll.user32.SetProcessDPIAware()
    except (AttributeError, OSError):
        pass

import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from pathlib import Path
from PIL import Image, ImageOps, ImageTk
import core

BG = '#f2f1ed'
CARD = '#ffffff'
INK = '#303a35'
MUTED = '#737d76'
ACCENT = '#657d6e'
BORDER = '#e0e4dd'
MODES = {'等比黑边 · 720p': 'contain', '拉伸 · 720p': 'stretch', '保持原尺寸': 'original'}


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title('影序 · FPGA 素材管理')
        self.ui_scale = max(1.0, self.winfo_fpixels('1i') / 96.0)
        screen_w, screen_h = self.winfo_screenwidth(), self.winfo_screenheight()
        width = min(self.px(1220), int(screen_w * 0.94))
        height = min(self.px(790), int(screen_h * 0.88))
        self.geometry(f'{width}x{height}')
        self.minsize(min(self.px(900), width), min(self.px(650), height))
        icon = Path(getattr(sys, '_MEIPASS', Path(__file__).parent)) / 'app.ico'
        if sys.platform == 'win32' and icon.is_file():
            self.iconbitmap(default=str(icon))
        self.configure(bg=BG)
        self.project = {'pictures': [], 'audio': [], 'logo': '', 'channels': 'auto'}
        self.selected = None
        self.page = 'pictures'
        self.busy = False
        self.events = queue.Queue()
        self.thumbnail_cache = {}
        self.thumbnail_pending = set()
        self.thumbnail_jobs = queue.Queue()
        self.picture_rows = []
        self.drag_state = None
        self.bind('<Escape>', lambda event: self.cancel_drag())
        threading.Thread(target=self.thumbnail_worker, daemon=True).start()
        self.make_style()
        self.build_shell()
        self.show_page('pictures')
        self.poll_after = self.after(30, self.poll)

    def px(self, value):
        return max(1, round(value * self.ui_scale)) if value else 0

    def destroy(self):
        self.cancel_drag()
        if getattr(self, 'poll_after', None):
            self.after_cancel(self.poll_after)
            self.poll_after = None
        self.thumbnail_jobs.put(None)
        super().destroy()

    def make_style(self):
        s = ttk.Style(self)
        s.theme_use('clam')
        s.configure('.', font=('Microsoft YaHei UI', 10), background=CARD, foreground=INK)
        s.configure('TCombobox', fieldbackground=CARD, background=CARD, foreground=INK, padding=5)
        s.map('TCombobox', fieldbackground=[('readonly', CARD)], selectbackground=[('readonly', CARD)], selectforeground=[('readonly', INK)])
        s.configure('Vertical.TScrollbar', width=self.px(12))
        s.configure('Horizontal.TProgressbar', troughcolor=BORDER, background=ACCENT, bordercolor=BORDER, lightcolor=ACCENT, darkcolor=ACCENT)

    def label(self, parent, text, size=10, color=INK, bg=CARD, **kw):
        return tk.Label(parent, text=text, bg=bg, fg=color, font=('Microsoft YaHei UI', size), anchor='w', **kw)

    def button(self, parent, text, command, primary=False, **kw):
        options = dict(relief='flat', bd=0, padx=self.px(14), pady=self.px(8), bg=ACCENT if primary else '#edf1ec',
                       fg='white' if primary else INK, activebackground='#526b5b', activeforeground='white',
                       cursor='hand2', font=('Microsoft YaHei UI', 10))
        options.update(kw)
        return tk.Button(parent, text=text, command=command, **options)

    def card(self, parent):
        return tk.Frame(parent, bg=CARD, highlightbackground=BORDER, highlightthickness=1)

    def build_shell(self):
        self.sidebar = tk.Frame(self, bg='#e7eae4', width=self.px(195))
        self.sidebar.pack(side='left', fill='y')
        self.sidebar.pack_propagate(False)
        self.label(self.sidebar, '影 序', 23, bg='#e7eae4').pack(anchor='w', padx=self.px(24), pady=(self.px(30), self.px(0)))
        self.label(self.sidebar, 'FPGA 素材管理', 9, MUTED, '#e7eae4').pack(anchor='w', padx=self.px(25), pady=(self.px(3), self.px(35)))
        for title, page in [('素材与排序', 'pictures'), ('音频管理', 'audio'), ('台标设置', 'logo'), ('写入 SD 卡', 'write')]:
            self.button(self.sidebar, title, lambda p=page: self.show_page(p), anchor='w', bg='#e7eae4', activebackground='#d5ded6', activeforeground=INK).pack(fill='x', padx=self.px(12), pady=self.px(3))
        self.label(self.sidebar, 'MEDIA WORKSPACE\n为 FPGA 准备素材', 9, MUTED, '#e7eae4', justify='left').pack(side='bottom', anchor='w', padx=self.px(23), pady=self.px(30))
        self.body = tk.Frame(self, bg=BG)
        self.body.pack(side='left', fill='both', expand=True, padx=self.px(28), pady=self.px(22))
        top = tk.Frame(self.body, bg=BG)
        top.pack(fill='x', pady=(self.px(0), self.px(18)))
        self.title_label = self.label(top, '', 20, bg=BG)
        self.title_label.pack(side='left')
        self.button(top, '关于 / 许可证', self.show_about).pack(side='right', padx=(self.px(8), self.px(0)))
        self.button(top, '打开项目', self.load_project).pack(side='right', padx=(self.px(8), self.px(0)))
        self.button(top, '保存项目', self.save_project).pack(side='right')
        self.content = tk.Frame(self.body, bg=BG)
        self.content.pack(fill='both', expand=True)
        bottom = tk.Frame(self.body, bg=BG)
        bottom.pack(fill='x', pady=(self.px(12), self.px(0)))
        self.status = self.label(bottom, '准备就绪', 9, MUTED, BG)
        self.status.pack(side='left', fill='x', expand=True)
        self.progress = ttk.Progressbar(bottom, mode='indeterminate', length=self.px(135))
        self.progress.pack(side='right')

    def show_about(self):
        import sys
        base = Path(getattr(sys, '_MEIPASS', Path(__file__).parent))
        license_dir = base / 'audio-license'
        dialog = tk.Toplevel(self)
        dialog.title('关于与第三方许可证')
        dialog.geometry(f'{self.px(760)}x{self.px(520)}')
        text = tk.Text(dialog, wrap='word', padx=self.px(15), pady=self.px(15), font=('Microsoft YaHei UI', 10))
        text.pack(fill='both', expand=True)
        text.insert('end', '影序 · FPGA 素材管理\n\n本程序使用 miniaudio 音频解码库（MIT 许可证）。\n\n')
        for name in ('LICENSE',):
            file = license_dir / name
            if file.exists():
                text.insert('end', file.read_text(encoding='utf-8', errors='replace') + '\n\n')
        if not license_dir.exists():
            text.insert('end', '源码运行模式请参阅 miniaudio 软件包中的许可证。')
        text.configure(state='disabled')

    def show_page(self, page):
        if self.busy:
            return
        if self.page == 'pictures':
            self.cancel_drag()
            self.commit_detail()
        self.page = page
        for w in self.content.winfo_children():
            w.destroy()
        self.title_label.config(text={'pictures': '素材与播放顺序', 'audio': '音频管理', 'logo': '台标设置', 'write': '写入 SD 卡'}[page])
        getattr(self, 'page_' + page)()

    def page_pictures(self):
        bar = tk.Frame(self.content, bg=BG)
        bar.pack(fill='x', pady=(self.px(0), self.px(12)))
        self.label(bar, '拖动卡片调整顺序 · 最多 256 张图片', 10, MUTED, BG).pack(side='left')
        self.button(bar, '＋ 添加图片', self.add_pictures, True).pack(side='right')
        self.button(bar, '导出转换素材', self.export).pack(side='right', padx=self.px(8))
        left = self.card(self.content)
        left.pack(side='left', fill='both', expand=True, padx=(self.px(0), self.px(12)))
        self.detail = self.card(self.content)
        self.detail.pack(side='right', fill='y')
        self.detail.configure(width=self.px(330))
        self.detail.pack_propagate(False)
        self.canvas = tk.Canvas(left, bg=CARD, highlightthickness=0)
        scroll = ttk.Scrollbar(left, orient='vertical', command=self.canvas.yview)
        self.rows = tk.Frame(self.canvas, bg=CARD)
        self.canvas.create_window((0, 0), window=self.rows, anchor='nw', tags='rows')
        self.canvas.configure(yscrollcommand=scroll.set)
        self.rows.bind('<Configure>', lambda e: self.canvas.configure(scrollregion=self.canvas.bbox('all')))
        self.canvas.bind('<Configure>', lambda e: self.canvas.itemconfigure('rows', width=e.width))
        self.canvas.pack(side='left', fill='both', expand=True, padx=self.px(12), pady=self.px(12))
        scroll.pack(side='right', fill='y')
        self.canvas.bind('<MouseWheel>', self.scroll_pictures)
        self.rows.bind('<MouseWheel>', self.scroll_pictures)
        self.refresh_rows()
        self.refresh_detail()

    def thumbnail_worker(self):
        # Pillow work stays off the Tk thread; PhotoImage is created on it.
        while True:
            path = self.thumbnail_jobs.get()
            if path is None:
                return
            try:
                with Image.open(path) as image:
                    image.thumbnail((220, 220), Image.Resampling.LANCZOS)
                    thumb = ImageOps.fit(ImageOps.exif_transpose(image).convert('RGB'),
                                         (self.px(92), self.px(60)), method=Image.Resampling.LANCZOS)
                self.events.put(('thumbnail', (path, thumb)))
            except (OSError, ValueError, Image.DecompressionBombError):
                self.events.put(('thumbnail', (path, None)))

    def update_thumbnail(self, path, thumb):
        self.thumbnail_pending.discard(path)
        photo = ImageTk.PhotoImage(thumb, master=self) if thumb is not None else None
        self.thumbnail_cache[path] = photo
        if self.page != 'pictures':
            return
        for row in self.picture_rows:
            if row['item']['path'] == path and row['image'].winfo_exists():
                row['image'].configure(image=photo or '', text='' if photo else '无法预览', width=0 if photo else 12)

    def refresh_rows(self):
        self.cancel_drag()
        for widget in self.rows.winfo_children():
            widget.destroy()
        self.picture_rows = []
        pics = self.project['pictures']
        if not pics:
            self.label(self.rows, '还没有图片\n\n添加素材后，在这里调整播放顺序。', 11, MUTED, justify='left').pack(anchor='w', padx=self.px(20), pady=self.px(40))
        for item in pics:
            background = '#f8f9f7'
            frame = tk.Frame(self.rows, bg=background, pady=self.px(10), padx=self.px(10))
            frame.pack(fill='x', pady=self.px(4))
            image = tk.Label(frame, text='加载中', bg=background, fg=MUTED, width=12,
                             cursor='hand2')
            image.pack(side='left', padx=(self.px(0), self.px(12)))
            path = item['path']
            if path in self.thumbnail_cache:
                photo = self.thumbnail_cache[path]
                image.configure(image=photo or '', text='' if photo else '无法预览', width=0 if photo else 12)
            elif path not in self.thumbnail_pending:
                self.thumbnail_pending.add(path)
                self.thumbnail_jobs.put(path)
            info = tk.Frame(frame, bg=background, cursor='hand2')
            info.pack(side='left', fill='x', expand=True)
            title = self.label(info, '', 10, INK, background)
            title.pack(anchor='w')
            meta = self.label(info, '', 9, MUTED, background)
            meta.pack(anchor='w', pady=(self.px(5), self.px(0)))
            row = {'item': item, 'frame': frame, 'image': image, 'info': info,
                   'title': title, 'meta': meta}
            self.picture_rows.append(row)
            for widget in (frame, image, info, title, meta):
                self.bind_drag(widget, row)
                widget.bind('<MouseWheel>', self.scroll_pictures)
            self.button(frame, '下移', lambda r=row: self.move_row(r, 1)).pack(side='right', padx=self.px(2))
            self.button(frame, '上移', lambda r=row: self.move_row(r, -1)).pack(side='right', padx=self.px(2))
        self.update_row_labels()
        self.update_selection()

    def update_row_labels(self, indexes=None):
        if indexes is None:
            indexes = range(len(self.picture_rows))
        for i in indexes:
            if i is None or not 0 <= i < len(self.picture_rows):
                continue
            row = self.picture_rows[i]
            p = row['item']
            row['title'].configure(text=f'{i+1:02d}   {Path(p["path"]).name}')
            mode = next((k for k, v in MODES.items() if v == p.get('mode')), '等比黑边 · 720p')
            row['meta'].configure(text=f'{mode}   ·   字幕 {"已设置" if p.get("subtitle") else "无"}   ·   配音 {"已设置" if p.get("audio") else "无"}')

    def update_selection(self, indexes=None):
        if indexes is None:
            indexes = range(len(self.picture_rows))
        for i in indexes:
            if i is None or not 0 <= i < len(self.picture_rows):
                continue
            row = self.picture_rows[i]
            color = '#edf2ed' if i == self.selected else '#f8f9f7'
            for key in ('frame', 'image', 'info', 'title', 'meta'):
                row[key].configure(bg=color)

    def scroll_pictures(self, event):
        self.canvas.yview_scroll(-1 if event.delta > 0 else 1, 'units')
        return 'break'

    def bind_drag(self, widget, row):
        widget.bind('<ButtonPress-1>', lambda event: self.drag_start(event, row))
        widget.bind('<B1-Motion>', self.drag_motion)
        widget.bind('<ButtonRelease-1>', self.drag_end)

    def drag_start(self, event, row):
        self.cancel_drag()
        self.drag_state = {'row': row, 'start_y': event.y_root, 'active': False,
                           'pointer_x': event.x_root, 'pointer_y': event.y_root,
                           'target': None, 'timer': None}

    def drag_motion(self, event):
        state = self.drag_state
        if not state:
            return
        state['pointer_x'], state['pointer_y'] = event.x_root, event.y_root
        if not state['active']:
            if abs(event.y_root - state['start_y']) < 8:
                return
            self.select(self.picture_rows.index(state['row']))
            state['active'] = True
            ghost = tk.Toplevel(self)
            ghost.overrideredirect(True)
            ghost.attributes('-topmost', True)
            try:
                ghost.attributes('-alpha', 0.88)
            except tk.TclError:
                pass
            ghost.configure(bg=ACCENT, padx=self.px(2), pady=self.px(2))
            inner = tk.Frame(ghost, bg='#f8f9f7', padx=self.px(12), pady=self.px(8))
            inner.pack()
            photo = self.thumbnail_cache.get(state['row']['item']['path'])
            if photo:
                tk.Label(inner, image=photo, bg='#f8f9f7').pack(side='left', padx=(self.px(0), self.px(10)))
            self.label(inner, Path(state['row']['item']['path']).name, 10, INK, '#f8f9f7').pack(side='left')
            state['ghost'] = ghost
            state['marker'] = tk.Frame(self.rows, bg=ACCENT, height=self.px(4))
            self.drag_tick()
        self.drag_position()

    def drag_position(self):
        state = self.drag_state
        if not state or not state['active']:
            return
        x, y = state['pointer_x'], state['pointer_y']
        state['ghost'].geometry(f'+{max(0, x + 14)}+{max(0, y + 14)}')
        left, top = self.canvas.winfo_rootx(), self.canvas.winfo_rooty()
        inside = left <= x < left + self.canvas.winfo_width() and top <= y < top + self.canvas.winfo_height()
        marker = state['marker']
        if not inside:
            marker.pack_forget()
            state['target'] = None
            return
        target = len(self.picture_rows)
        for i, row in enumerate(self.picture_rows):
            frame = row['frame']
            if y < frame.winfo_rooty() + frame.winfo_height() / 2:
                target = i
                break
        if target != state['target']:
            marker.pack_forget()
            if target < len(self.picture_rows):
                marker.pack(fill='x', before=self.picture_rows[target]['frame'], pady=self.px(2))
            else:
                marker.pack(fill='x', pady=self.px(2))
            state['target'] = target

    def drag_tick(self):
        state = self.drag_state
        if not state or not state['active']:
            return
        top = self.canvas.winfo_rooty()
        y = state['pointer_y']
        x = state['pointer_x']
        if self.canvas.winfo_rootx() <= x < self.canvas.winfo_rootx() + self.canvas.winfo_width():
            if top <= y < top + 40:
                self.canvas.yview_scroll(-1, 'units')
            elif top + self.canvas.winfo_height() - 40 < y < top + self.canvas.winfo_height():
                self.canvas.yview_scroll(1, 'units')
            self.update_idletasks()
            self.drag_position()
        state['timer'] = self.after(45, self.drag_tick)

    def drag_end(self, event):
        state = self.drag_state
        if not state:
            return
        if not state['active']:
            row = state['row']
            self.cancel_drag()
            self.select(self.picture_rows.index(row))
            return
        self.drag_position()
        target, row = state['target'], state['row']
        self.cancel_drag()
        if target is None:
            return
        source = self.picture_rows.index(row)
        if target > source:
            target -= 1
        if target == source:
            return
        self.commit_detail()
        self.picture_rows.pop(source)
        self.picture_rows.insert(target, row)
        item = self.project['pictures'].pop(source)
        self.project['pictures'].insert(target, item)
        self.selected = target
        self.repack_rows()
        self.update_row_labels()
        self.update_selection()

    def cancel_drag(self):
        state = self.drag_state
        self.drag_state = None
        if not state:
            return
        if state.get('timer'):
            self.after_cancel(state['timer'])
        for key in ('marker', 'ghost'):
            if state.get(key):
                state[key].destroy()

    def repack_rows(self):
        for row in self.picture_rows:
            row['frame'].pack_forget()
        for row in self.picture_rows:
            row['frame'].pack(fill='x', pady=self.px(4))

    def move_row(self, row, step):
        self.move(self.picture_rows.index(row), step)

    def add_pictures(self):
        paths = filedialog.askopenfilenames(filetypes=[('图片', '*.jpg *.jpeg *.png *.bmp')])
        if not paths:
            return
        if len(self.project['pictures']) + len(paths) > 256:
            messagebox.showerror('数量超出限制', '普通图片最多 256 张。')
            return
        self.commit_detail()
        self.project['pictures'].extend({'path': str(Path(p).resolve()), 'mode': 'contain', 'subtitle': '', 'audio': ''} for p in paths)
        self.selected = len(self.project['pictures']) - len(paths)
        self.refresh_rows()
        self.refresh_detail()

    def select(self, i):
        old = self.selected
        self.commit_detail()
        self.selected = i
        self.update_row_labels((old, i))
        self.update_selection((old, i))
        self.refresh_detail()

    def move(self, i, step):
        j = i + step
        if not 0 <= j < len(self.project['pictures']):
            return
        self.commit_detail()
        p = self.project['pictures']
        p[i], p[j] = p[j], p[i]
        self.picture_rows[i], self.picture_rows[j] = self.picture_rows[j], self.picture_rows[i]
        if self.selected == i:
            self.selected = j
        elif self.selected == j:
            self.selected = i
        self.update_row_labels()
        self.update_selection()
        self.refresh_detail()

    def commit_detail(self):
        if self.selected is None or not hasattr(self, 'mode_var') or self.page != 'pictures':
            return
        if not 0 <= self.selected < len(self.project['pictures']):
            return
        p = self.project['pictures'][self.selected]
        p['mode'] = MODES.get(self.mode_var.get(), 'contain')
        p['subtitle'] = self.subtitle_var.get()

    def refresh_detail(self):
        for w in self.detail.winfo_children():
            w.destroy()
        self.mode_var = None
        if self.selected is None or self.selected >= len(self.project['pictures']):
            self.label(self.detail, '选择一张图片', 13).pack(anchor='w', padx=self.px(22), pady=(self.px(25), self.px(10)))
            self.label(self.detail, '设置转换方式、字幕和配音。', 10, MUTED).pack(anchor='w', padx=self.px(22))
            return
        p = self.project['pictures'][self.selected]
        box = tk.Frame(self.detail, bg=CARD)
        box.pack(fill='both', expand=True, padx=self.px(20), pady=self.px(20))
        self.label(box, '图片设置', 15).pack(anchor='w', pady=(self.px(0), self.px(6)))
        self.label(box, Path(p['path']).name, 9, MUTED, wraplength=self.px(270)).pack(anchor='w', pady=(self.px(0), self.px(20)))
        self.label(box, '转换方式', 10).pack(anchor='w')
        self.mode_var = tk.StringVar(value=next((k for k,v in MODES.items() if v == p.get('mode')), list(MODES)[0]))
        ttk.Combobox(box, textvariable=self.mode_var, values=list(MODES), state='readonly').pack(fill='x', pady=(self.px(7), self.px(16)))
        self.label(box, '字幕', 10).pack(anchor='w')
        self.subtitle_var = tk.StringVar(value=p.get('subtitle', ''))
        tk.Entry(box, textvariable=self.subtitle_var, relief='solid', bd=1, font=('Microsoft YaHei UI', 10)).pack(fill='x', pady=(self.px(7), self.px(4)), ipady=self.px(6))
        self.label(box, '仅支持英文和 ASCII 符号，最多 256 字符。\n长字幕在设备上滚动。', 9, MUTED, justify='left', wraplength=self.px(275)).pack(anchor='w', pady=(self.px(0), self.px(18)))
        self.label(box, '图片配音', 10).pack(anchor='w')
        self.label(box, Path(p['audio']).name if p.get('audio') else '未选择', 9, MUTED, wraplength=self.px(270)).pack(anchor='w', pady=self.px(7))
        self.button(box, '选择配音', self.pick_companion).pack(anchor='w')
        if p.get('audio'):
            self.button(box, '移除配音', self.remove_companion).pack(anchor='w', pady=self.px(5))
        self.label(box, '开启轮播时，有配音的图片会在配音结束后切换。', 9, MUTED, wraplength=self.px(275), justify='left').pack(anchor='w', pady=self.px(12))
        self.button(box, '移除图片', self.remove_picture).pack(side='bottom', anchor='w')

    def pick_companion(self):
        path = filedialog.askopenfilename(filetypes=[('音频', '*.mp3 *.wav')])
        if path:
            self.commit_detail()
            self.project['pictures'][self.selected]['audio'] = str(Path(path).resolve())
            self.update_row_labels(); self.refresh_detail()

    def remove_companion(self):
        self.commit_detail(); self.project['pictures'][self.selected]['audio'] = ''
        self.update_row_labels(); self.refresh_detail()

    def remove_picture(self):
        self.project['pictures'].pop(self.selected)
        self.selected = None
        self.refresh_rows(); self.refresh_detail()

    def page_audio(self):
        card = self.card(self.content); card.pack(fill='both', expand=True)
        box = tk.Frame(card, bg=CARD); box.pack(fill='both', expand=True, padx=self.px(24), pady=self.px(24))
        self.label(box, '背景音乐', 15).pack(anchor='w')
        self.label(box, '输出为 48 kHz / 16 位 PCM WAV。图片配音可在素材页面设置。', 10, MUTED).pack(anchor='w', pady=(self.px(6), self.px(18)))
        actions = tk.Frame(box, bg=CARD); actions.pack(fill='x')
        self.button(actions, '＋ 添加音频', self.add_audio, True).pack(side='left')
        self.button(actions, '移除选中', self.remove_audio).pack(side='left', padx=self.px(8))
        self.label(actions, '输出声道', 10).pack(side='left', padx=(self.px(20), self.px(8)))
        self.channel_var = tk.StringVar(value={'auto':'自动', '1':'单声道', '2':'立体声'}.get(self.project.get('channels'), '自动'))
        cb = ttk.Combobox(actions, textvariable=self.channel_var, values=['自动', '单声道', '立体声'], state='readonly', width=10)
        cb.pack(side='left'); cb.bind('<<ComboboxSelected>>', lambda e: self.project.update(channels={'自动':'auto', '单声道':'1', '立体声':'2'}[self.channel_var.get()]))
        self.audio_list = tk.Listbox(box, bg='#f8f9f7', fg=INK, relief='flat', selectbackground=ACCENT, font=('Microsoft YaHei UI', 11), activestyle='none')
        self.audio_list.pack(fill='both', expand=True, pady=self.px(18))
        for p in self.project['audio']:
            self.audio_list.insert('end', Path(p).name + '    —    ' + p)

    def add_audio(self):
        self.project['audio'].extend(str(Path(p).resolve()) for p in filedialog.askopenfilenames(filetypes=[('音频', '*.mp3 *.wav')]))
        self.show_page('audio')

    def remove_audio(self):
        for i in reversed(self.audio_list.curselection()):
            self.project['audio'].pop(i)
        self.show_page('audio')

    def page_logo(self):
        card = self.card(self.content); card.pack(fill='both', expand=True)
        box = tk.Frame(card, bg=CARD); box.pack(anchor='nw', padx=self.px(26), pady=self.px(26))
        self.label(box, '固定台标', 15).pack(anchor='w')
        self.label(box, '自动转换为 64×64、无透明通道的 OVERLAY.BMP，显示在画面右上角。', 10, MUTED, wraplength=self.px(600)).pack(anchor='w', pady=(self.px(8), self.px(20)))
        path = self.project.get('logo')
        if path:
            try:
                with Image.open(path) as im:
                    image = ImageOps.exif_transpose(im).convert('RGB').resize((self.px(192), self.px(192)))
                self.logo_image = ImageTk.PhotoImage(image)
                tk.Label(box, image=self.logo_image, bg=CARD).pack(anchor='w')
            except OSError:
                self.label(box, '无法预览源文件', 10, MUTED).pack(anchor='w')
            self.label(box, Path(path).name, 10).pack(anchor='w', pady=self.px(8))
        self.button(box, '选择台标', self.pick_logo, True).pack(anchor='w', pady=self.px(8))
        if path:
            self.button(box, '移除台标', lambda: (self.project.update(logo=''), self.show_page('logo'))).pack(anchor='w')

    def pick_logo(self):
        p = filedialog.askopenfilename(filetypes=[('图片', '*.jpg *.jpeg *.png *.bmp')])
        if p:
            self.project['logo'] = str(Path(p).resolve()); self.show_page('logo')

    def page_write(self):
        card = self.card(self.content); card.pack(fill='both', expand=True)
        box = tk.Frame(card, bg=CARD); box.pack(fill='both', expand=True, padx=self.px(26), pady=self.px(25))
        self.label(box, '准备写入', 15).pack(anchor='w')
        self.label(box, '选择空根目录的 FAT32 可移动磁盘。程序不会自动删除或格式化文件。', 10, MUTED, wraplength=self.px(730)).pack(anchor='w', pady=(self.px(7), self.px(20)))
        self.label(box, '目标磁盘', 10).pack(anchor='w')
        self.drive_var = tk.StringVar()
        self.drive_combo = ttk.Combobox(box, textvariable=self.drive_var, state='readonly', width=55)
        self.drive_combo.pack(anchor='w', fill='x', pady=(self.px(7), self.px(8)))
        self.button(box, '刷新磁盘', self.refresh_drives).pack(anchor='w')
        self.refresh_drives()
        n = len(self.project['pictures']); a = len(self.project['audio']) + sum(bool(p.get('audio')) for p in self.project['pictures'])
        self.label(box, f'待处理：{n} 张图片  ·  {a} 首音频  ·  台标 {"已选择" if self.project.get("logo") else "无"}', 11).pack(anchor='w', pady=(self.px(25), self.px(10)))
        estimate = self.label(box, '正在估算素材空间…', 10, MUTED)
        estimate.pack(anchor='w')
        snapshot = json.loads(json.dumps(self.project))
        def estimate_worker():
            size, unknown = core.estimate_size(snapshot)
            self.events.put(('estimate', (estimate, size, unknown)))
        threading.Thread(target=estimate_worker, daemon=True).start()
        self.label(box, '写入前转换并计算实际空间；完成后逐文件核验，并检查 FPGA 实际读取的图片顺序。\n完成后安全移除 SD 卡，插入 media 板并复位。自动字幕和轮播需在设备菜单开启。', 10, MUTED, wraplength=self.px(730), justify='left').pack(anchor='w', pady=self.px(8))
        self.button(box, '转换并写入 SD 卡', self.write_card, True).pack(anchor='w', pady=self.px(20))

    def refresh_drives(self):
        options = [f'{root}  |  {label or "无卷标"}  |  {fs}  |  可用 {shutil.disk_usage(root).free / 1024**3:.1f} GB' for root, label, fs in core.drives()]
        self.drive_combo['values'] = options
        self.drive_var.set(options[0] if options else '')

    def save_project(self):
        self.commit_detail()
        path = filedialog.asksaveasfilename(defaultextension='.json', filetypes=[('素材项目', '*.json')])
        if path:
            try:
                Path(path).write_text(json.dumps({'version': 1, **self.project}, ensure_ascii=False, indent=2), encoding='utf-8')
            except OSError as e:
                messagebox.showerror('保存失败', str(e))

    def load_project(self):
        path = filedialog.askopenfilename(filetypes=[('素材项目', '*.json')])
        if path:
            try:
                p = json.loads(Path(path).read_text(encoding='utf-8'))
                if p.get('version') != 1 or not isinstance(p.get('pictures'), list) or not isinstance(p.get('audio'), list):
                    raise ValueError('项目格式不正确')
                self.project = {k: p.get(k, v) for k, v in {'pictures': [], 'audio': [], 'logo': '', 'channels': 'auto'}.items()}
                self.selected = None; self.page = ''; self.show_page('pictures')
            except (OSError, ValueError, TypeError) as e:
                messagebox.showerror('打开失败', str(e))

    def run_job(self, job):
        if self.busy:
            return
        self.busy = True; self.progress.start(12)
        snapshot = json.loads(json.dumps(self.project))
        def worker():
            try:
                result = job(snapshot, lambda s: self.events.put(('progress', s)))
                self.events.put(('done', result))
            except Exception as e:
                self.events.put(('error', str(e)))
        threading.Thread(target=worker, daemon=True).start()

    def poll(self):
        try:
            for _ in range(20):
                kind, value = self.events.get_nowait()
                if kind == 'thumbnail':
                    self.update_thumbnail(*value)
                elif kind == 'progress':
                    self.status.config(text=value)
                elif kind == 'estimate':
                    widget, size, unknown = value
                    if widget.winfo_exists():
                        widget.config(text=f'预计约 {size / 1024**2:.1f} MB' + (f'，{unknown} 个素材无法估算' if unknown else '（音频按立体声估算）'))
                else:
                    self.progress.stop(); self.busy = False
                    self.status.config(text='准备就绪' if kind == 'done' else '操作失败')
                    if kind == 'done':
                        messagebox.showinfo('操作完成', value)
                    else:
                        messagebox.showerror('操作失败', value + '\n\n如写卡已开始，部分文件可能已写入，请检查目标磁盘。')
        except queue.Empty:
            pass
        self.poll_after = self.after(30, self.poll)

    def export(self):
        self.commit_detail()
        folder = filedialog.askdirectory(title='选择空的导出文件夹')
        if not folder:
            return
        def work(project, progress):
            dest = Path(folder)
            if any(dest.iterdir()):
                raise ValueError('导出文件夹必须为空')
            with tempfile.TemporaryDirectory(prefix='fpga_export_') as tmp:
                names = core.prepare(project, tmp, progress)
                for name in names:
                    with open(Path(tmp) / name, 'rb') as src, open(dest / name, 'xb') as dst:
                        shutil.copyfileobj(src, dst)
            return f'已导出 {len(names)} 个文件到 {dest}。'
        self.run_job(work)

    def write_card(self):
        choice = self.drive_var.get()
        if not choice:
            messagebox.showerror('未选择磁盘', '没有可用的可移动磁盘。'); return
        root = choice.split('  |  ')[0]
        if not messagebox.askyesno('确认写入', f'确认将素材写入 {choice}？\n目标根目录必须为空。'):
            return
        self.run_job(lambda project, progress: f'已写入并核验 {core.deploy(project, root, progress)} 个文件。\n请安全移除 SD 卡后插入 media 板并复位。')


def self_test(output):
    import sys
    import wave
    report = {}
    try:
        base = Path(getattr(sys, '_MEIPASS', Path(__file__).parent))
        source = base / 'test_data' / 'smoke.mp3'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            core.audio_convert(source, root / 'output.wav')
            with wave.open(str(root / 'output.wav'), 'rb') as audio:
                if (audio.getframerate(), audio.getsampwidth(), audio.getnchannels()) != (48000, 2, 1) or not audio.getnframes():
                    raise RuntimeError('unexpected output WAV format')
            Image.new('RGB', (20, 15), 'red').save(root / 'input.png')
            core.image_convert(root / 'input.png', root / 'output.bmp', 'original')
        window = App()
        window.withdraw()
        window.update()
        window.destroy()
        report = {'ok': True, 'mp3_conversion': True, 'bmp_conversion': True, 'gui': True}
    except Exception as exc:
        report = {'ok': False, 'error': repr(exc)}
    Path(output).write_text(json.dumps(report, ensure_ascii=False), encoding='utf-8')
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == '--self-test':
        raise SystemExit(self_test(sys.argv[2]))
    App().mainloop()
