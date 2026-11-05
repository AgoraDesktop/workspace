/*
 * WSQuickLookController.h — the panel a spacebar opens on the selection.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A QUICK LOOK IS A GLANCE, NOT A WINDOW A PERSON MANAGES.** It has no title bar, no resize handle and no place in the
 * window list: one click or one space and it is gone, and it never takes the keyboard from the window holding the
 * selection. So the panel is BORDERLESS and NOT ACTIVATABLE, its keys stay with the file window's view, and everything it
 * can do is what a glance needs — show the thing, and say what it is.
 *
 * **WHAT IT CAN SHOW IS WHAT THIS TREE CAN DECODE, NOT A LIST OF EXTENSIONS.** An image is asked of the AppKit's
 * representation registry — the same `AGImageSourceRep` the Viewer uses, so every format the drawing library decodes
 * (PNG, JPEG, TIFF, WebP, GIF, BMP, ICO, ICNS, TGA, JPEG 2000, HEIC, AVIF, EXR…) is a picture here without a second list
 * going stale. A PDF is drawn as a PAGE, through `NSPDFImageRep`, so its text stays vector. A text file is a few thousand
 * bytes drawn in a monospaced face. A folder and anything else get the item's own icon and the facts a glance needs.
 */
#ifndef WORKSPACE_WSQUICKLOOKCONTROLLER_H
#define WORKSPACE_WSQUICKLOOKCONTROLLER_H

#import <AppKit/NSWindowController.h>

#import <Foundation/Foundation.h>

@class NSView;

NS_ASSUME_NONNULL_BEGIN

/* WHAT THE PANEL WILL DRAW, decided from the file's BYTES for the two kinds that need bytes (image, text) and from the
 * file system for the other three. Nil-safe: a path that does not exist is `WSQuickLookKindOther`. */
typedef enum {
	WSQuickLookKindImage = 0,	/* something the representation registry claims */
	WSQuickLookKindPDF,		/* `%PDF-`, drawn as a page */
	WSQuickLookKindText,		/* no NUL bytes and mostly printable */
	WSQuickLookKindFolder,
	WSQuickLookKindOther
} WSQuickLookKind;

@interface WSQuickLookController : NSWindowController
{
	NSString *_path;	/* RETAINED: what the panel is showing, or nil */
	NSView *_panelView;	/* RETAINED by the panel's content view */
}

/* ONE PANEL FOR THE APPLICATION: a glance replaces the last glance rather than stacking. */
+ (instancetype)sharedController;

@property (readonly, nullable, copy) NSString *path;

- (BOOL)isShowing;
- (void)showForPath:(NSString *)path;
- (void)hide;

/* **THE KIND AND THE TEXT PREVIEW ARE CLASS DOORS SO A PROBE CAN ASK WITHOUT A DISPLAY.** The panel cannot be tested
 * headlessly — a window needs a server — but what it DECIDES can, and that is the half where a mistake is silent. */
+ (WSQuickLookKind)kindForPath:(nullable NSString *)path;

/* The text to draw for a text file: the first `limit` bytes, decoded as UTF-8 and cut at a line boundary. Nil when the
 * file is not text. */
+ (nullable NSString *)textPreviewForPath:(nullable NSString *)path limit:(NSUInteger)limit;

/* What the panel calls the thing: "Image", "PDF document", "Text", "Folder" or the file's own kind string. */
- (nullable NSString *)kindName;

@end

NS_ASSUME_NONNULL_END

#endif /* WORKSPACE_WSQUICKLOOKCONTROLLER_H */
