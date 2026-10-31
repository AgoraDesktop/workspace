/*
 * WSIconCell.h — one icon's presentation, so the desktop and a file window draw the same one.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **AN ICON AND ITS NAME ARE ONE CELL, AND A WASH UNDER THEM IS ONE RECTANGLE.** Both surfaces draw that cell — the grid,
 * the spacing and the label's cut already come from `WSIconLayout`, and this is the other half: the selection's wash, the
 * ring that goes with key focus, and the order the three are painted in. It lives here because the two views had drifted:
 * the desktop filled a square four points outside the ICON, unrounded and stopping above the name, so a desktop selection
 * was a blue blob that did not look like the same gesture as a file window's.
 *
 * The rule the rectangle follows is `WSIconLayout`'s cell: **the highlight is the cell's WIDTH, centred on the icon, and
 * tall enough to hold the icon, the label and `WSIconHighlightInset` points of air** — which is why a fill, a clip and a
 * ring can all be the same shape.
 *
 * **THE INK IS THE CALLER'S, BECAUSE THE BACKGROUND IS.** A file window's background is white and its names are black; the
 * desktop's is a wallpaper, so its names are white. That difference is about what is BEHIND the text, not about the
 * selection, and a white wash of accent over a photograph cannot make black text readable. Everything else — the wash's
 * colour and alpha, the corner radius, the ring, the label's position and cut — is shared, so a desktop selection and a
 * file window's selection are the same object drawn over different backgrounds.
 */
#ifndef WORKSPACE_WSICONCELL_H
#define WORKSPACE_WSICONCELL_H

#import <Foundation/NSGeometry.h>
#import <Foundation/NSObject.h>

@class NSColor;
@class NSDictionary;
@class NSImage;
@class NSString;

/* The air between the icon and its name — the rename field must land exactly on the label, so it is public. */
extern const NSInteger WSIconLabelGap;
/* The air between a selection's edge and what it contains. */
extern const NSInteger WSIconHighlightInset;
/* The corner the wash and the ring are both rounded by. */
extern const NSInteger WSIconHighlightRadius;
/* **HOW FAR AN INVALIDATION MUST REACH PAST THE HIGHLIGHT.** The ring is stroked ON the edge, so it paints half a point
 * outside and antialiases a point either side: TWO points, MEASURED on a live screen, where one cleared the stroke and
 * left a ghost of its antialiasing behind each time the selection moved. */
extern const NSInteger WSIconHighlightSlop;

/* **THE WASH'S COLOUR, SO NOTHING HAS TO REPEAT THE TRIPLE** — the views draw it and a probe measures it against white. It
 * is a fill with an alpha rather than a plate, which is why what a person sees is this colour composited over the surface
 * behind it. */
NSColor *WSIconCellSelectionColor(void);

/* **WHICH WAY THE NAME HANGS OFF THE ICON IS THE VIEW'S COORDINATE SYSTEM, NOT THE STYLE'S.** A file window is flipped
 * (`y` grows downward) so `NSMaxY (iconRect)` is BELOW the icon and the name goes there; the desktop is unflipped, where
 * the same expression is ABOVE it. The caller says which, and one function answers the name's rectangle and the highlight
 * that must enclose icon and name on the right side. */
NSRect WSIconCellHighlightRect(NSRect iconRect, CGFloat cellWidth, BOOL labelBelow);

/* One cell, as the views draw it. `label` is the name ALREADY CUT to the cell (`WSIconLabelText`), because the cut is a
 * measurement and each view does it for the widths its own layout has. */
typedef struct WSIconCell {
	NSRect iconRect;		/* the icon, in the view's coordinates */
	CGFloat cellWidth;		/* `+[WSIconLayout cellSizeForIconSize:]`'s width */
	NSImage *icon;			/* NOT RETAINED; nil draws no icon and still paints the cell */
	NSString *label;		/* NOT RETAINED; nil draws no name */
	NSDictionary *attributes;	/* the ink the name is drawn in */
	BOOL labelBelow;		/* YES in a flipped view, NO in an unflipped one — see the highlight's doc */
	BOOL selected;
	BOOL focused;			/* the view's window has the keyboard: a selected cell wears the ring */
} WSIconCell;

/* **THE WASH, THEN THE ICON, THEN THE NAME, THEN THE RING** — the order that keeps the selection's outline off the glyphs
 * and the name inside the wash. */
void WSIconCellDraw(WSIconCell cell);

#endif /* WORKSPACE_WSICONCELL_H */
