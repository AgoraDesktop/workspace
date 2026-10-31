/*
 * WSIconCell.m — the wash, the icon, the name and the ring, in that order.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSIconCell.h"

#import "WSIconLayout.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSStringDrawing.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSString.h>

#include <CoreGraphics/CGContext.h>

#include <math.h>

NSColor *WSIconCellSelectionColor(void)
{
	/* **A WASH, NOT A PLATE.** Thirty-five percent of the selection's blue: enough to say "this one" over white and over a
	 * wallpaper, and never enough to hide what it is saying it about. */
	return [NSColor colorWithCalibratedRed:0.30 green:0.50 blue:0.90 alpha:0.35];
}

/* **THE AIR BETWEEN AN ICON AND ITS NAME, AS ONE NUMBER FOR BOTH SURFACES.** Two points, and a line's own leading adds
 * the rest, so the first row of ink lands a few rows below the icon box. */
const NSInteger WSIconLabelGap = 2;
const NSInteger WSIconHighlightInset = 2;
const NSInteger WSIconHighlightRadius = 4;
const NSInteger WSIconHighlightSlop = 2;

/* **THE NAME'S RECTANGLE, ON WHICHEVER SIDE THE VIEW PUTS IT.** A cut name has an advance, and the rectangle handed to
 * `-drawInRect:` is exactly as wide, ROUNDED UP because a rect exactly as wide as the advance clips the last glyph. */
static NSRect fn_label_rect(NSRect iconRect, BOOL labelBelow, CGFloat labelWidth, CGFloat labelHeight)
{
	CGFloat y = labelBelow ? NSMaxY(iconRect) + (CGFloat)WSIconLabelGap
			       : NSMinY(iconRect) - (CGFloat)WSIconLabelGap - labelHeight;

	return NSMakeRect(NSMidX(iconRect) - labelWidth / 2.0, y, labelWidth, labelHeight);
}

NSRect WSIconCellHighlightRect(NSRect iconRect, CGFloat cellWidth, BOOL labelBelow)
{
	CGFloat side = (cellWidth - iconRect.size.width) / 2.0;

	return NSMakeRect(iconRect.origin.x - side,
			  labelBelow
				? iconRect.origin.y - (CGFloat)WSIconHighlightInset
				: NSMinY(iconRect) - (CGFloat)WSIconLabelGap - (CGFloat)WSIconLabelHeight
				  - (CGFloat)WSIconHighlightInset,
			  cellWidth,
			  iconRect.size.height + (CGFloat)WSIconLabelGap + (CGFloat)WSIconLabelHeight +
			  2.0 * (CGFloat)WSIconHighlightInset);
}

void WSIconCellDraw(WSIconCell cell)
{
	/* **THE NAME IS CENTRED ON THE ICON, NOT ON THE CELL.** The cell's left edge is the icon's and carries its padding to
	 * the right, so a name centred on the cell sat a padded half-cell off the folder it named. */
	NSRect highlight = WSIconCellHighlightRect(cell.iconRect, cell.cellWidth, cell.labelBelow);

	if (cell.selected) {
		/* **THE HIGHLIGHT IS SEMITRANSPARENT AND STAYS THAT WAY.** One fill of the selection's colour at its own alpha:
		 * whatever is behind the cell — a white page, a photograph, another window — shows through it, which is what makes
		 * the wash a wash rather than a plate. Nothing is laid beneath it, so the SAME colour covers the same pixels on
		 * every surface and the background is the only thing that differs. */
		[WSIconCellSelectionColor() setFill];
		[[NSBezierPath bezierPathWithRoundedRect:highlight
						 xRadius:(CGFloat)WSIconHighlightRadius
						 yRadius:(CGFloat)WSIconHighlightRadius] fill];
	}
	if (cell.icon != nil) {
		[cell.icon drawInRect:cell.iconRect];
	}
	if (cell.label != nil) {
		/* **THE INK IS THE SURFACE'S, SELECTED OR NOT, BECAUSE THE WASH IS SEMITRANSPARENT.** A wash lets the background
		 * through, so what a name is read against does not change when the cell is chosen: black on a file window's page,
		 * white on a wallpaper. The colour is the one thing the two surfaces legitimately disagree about, and it is about
		 * what is BEHIND the text. */
		NSDictionary *attributes = cell.attributes;
		NSSize size = [cell.label sizeWithAttributes:attributes];
		/* **THE BOX IS THE TEXT'S OWN HEIGHT, NOT A BAND OF SIXTEEN.** A fixed band leaves the space between the icon and
		 * the first row of ink up to whatever the drawing engine does inside it — and that answer differs by a point or two
		 * between a flipped view and an unflipped one, which is a gap that cannot be reasoned about and cannot be tuned. A
		 * box the height of the line leaves only the font's own leading, which is the same on both surfaces. */
		NSRect rect = fn_label_rect(cell.iconRect, cell.labelBelow, ceil(size.width), ceil(size.height));

		/* **CLIPPED TO THE HIGHLIGHT, WHICH IS THE LAST GUARD AGAINST A NAME SPILLING INTO ITS NEIGHBOUR.** The cut has
		 * already made it fit the cell; the clip is what keeps a rounding error or a kern pair inside. */
		[NSGraphicsContext saveGraphicsState];
		[[NSBezierPath bezierPathWithRect:highlight] addClip];
		/* **A NAME IS LAID OUT IN A MIRRORED FRAME ON BOTH SURFACES.** The engine places a line from ONE edge of the box
		 * it is handed — measured, a flipped view's name starts at the edge nearest the icon and an unflipped view's a
		 * few points further in — so the same constant put the same name at two different distances on the desktop and
		 * in a file window. Mirroring the CTM about the label's own rectangle (which maps the rectangle onto itself)
		 * makes the unflipped case lay the line out the way the flipped one already does; the glyphs stay upright, since
		 * this Core Graphics' show-glyphs takes the pen from the CTM and draws the face in its own direction. */
		if (!cell.labelBelow) {
			CGContextRef context = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];

			CGContextTranslateCTM(context, 0.0, NSMinY(rect) + NSMaxY(rect));
			CGContextScaleCTM(context, 1.0, -1.0);
		}
		if (cell.labelShadow) {
			/* **A WHITE NAME OVER A WALLPAPER GETS A BLACK SHADOW; A BLACK NAME ON A PAGE DOES NOT.** The shadow is one
			 * more draw of the same name in black, one point down and right, so the ink keeps its shape and gains an
			 * edge whatever it is over instead of a second font or a plate.
			 * shortcut: a hard one-point shadow, not a blur; upgrade if a screenshot asks for softness. */
			NSMutableDictionary *shadowInk = [[NSMutableDictionary alloc] initWithDictionary:attributes];

			[shadowInk setObject:[NSColor blackColor] forKey:NSForegroundColorAttributeName];
			[cell.label drawInRect:NSOffsetRect(rect, 1.0, 1.0) withAttributes:shadowInk];
			[shadowInk release];
		}
		[cell.label drawInRect:rect withAttributes:attributes];
		[NSGraphicsContext restoreGraphicsState];
	}
	/* **THE RING IS THE HIGHLIGHT'S OUTLINE AND IT IS DRAWN LAST**, so it is never painted over — and it goes on the
	 * same rectangle as the wash, which is what makes the colour and the outline one shape. */
	if (cell.selected && cell.focused) {
		[[NSColor darkGrayColor] setStroke];
		[[NSBezierPath bezierPathWithRoundedRect:highlight
						 xRadius:(CGFloat)WSIconHighlightRadius
						 yRadius:(CGFloat)WSIconHighlightRadius] stroke];
	}
}
