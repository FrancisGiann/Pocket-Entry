package dev.giann.pocket_entry

import org.junit.Assert.*
import org.junit.Test

class QuickEntryPolicyTest {
    @Test fun shortcutOpensOnlyAnUnselectedDraft() {
        assertEquals(QuickEntryPolicy.Route(null, null), QuickEntryPolicy.parse(QuickEntryPolicy.ACTION, null))
        assertNull(QuickEntryPolicy.parse("android.intent.action.VIEW", "pocketentry://quick/food"))
    }
    @Test fun categoriesAndWidgetIdentityAreValidated() {
        assertEquals(QuickEntryPolicy.Route("food", 12), QuickEntryPolicy.parse(QuickEntryPolicy.ACTION, "pocketentry://quick/food?widget=12"))
        for (uri in listOf("https://quick/food", "pocketentry://other/food", "pocketentry://quick/../food", "pocketentry://quick/food/bills", "pocketentry://quick/food?wallet=gcash", "pocketentry://quick/food?amount=500", "pocketentry://quick/food?widget=0", "pocketentry://quick/food?widget=-1", "pocketentry://quick/food?widget=12&amount=5", "pocketentry://user@quick/food", "pocketentry://quick:99/food", "pocketentry://quick/food#save", "pocketentry://quick/food?widget=9999999999")) {
            assertNull(uri, QuickEntryPolicy.parse(QuickEntryPolicy.ACTION, uri))
        }
    }
}
