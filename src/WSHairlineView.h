/* Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import <AppKit/NSView.h>

/* **A ONE-POINT RULE BETWEEN TWO STRIPS OF CHROME.** The window's strips meet each other and the content pane, and the
 * tier's own border grey — `controlDarkShadowColor`, the colour the split view's grips and the browser's column rules
 * use — is what marks each meeting. A strip that is a control draws its own border; the status bar is a bare label, so
 * the rule it needs is this view, pinned between it and the pane above. */
@interface WSHairlineView : NSView
@end
