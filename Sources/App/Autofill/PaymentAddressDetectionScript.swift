import Foundation

/// The document-start script for card & address autofill (browser-ojh.2),
/// injected alongside PasswordDetectionScript from Tab.engineTabDidStartMainFrameLoad.
/// Implements the *same* classification rules as
/// AutofillCore's FieldClassifier.swift by hand, in JS, for use inside the
/// page (a `<script>` can't call into a Swift package) -- kept in sync
/// manually; any change to one's classification rules should have a
/// matching change made to the other. FieldClassifier's own test suite
/// (Packages/AutofillCore/Tests) is the actual verification for these
/// rules; this file is a straight, careful hand-port of the same logic.
///
/// Three jobs:
///   1. On focus of any recognized card/address field, report which group
///      ("card" or "address") the nearest enclosing form belongs to, via a
///      "autofillFieldFocused" cefQuery message -- drives the omnibox-area
///      fill-icon (PaymentAddressCoordinator, next commit).
///   2. On blur (focus leaving every recognized field), report
///      "autofillFieldBlurred" so the icon can hide again.
///   3. On submit of a form that looks like a completed card or address
///      form, report the (non-CSC) field values via
///      "paymentFormSubmit"/"addressFormSubmit" -- drives the save prompt.
///
/// SECURITY: a CSC/CVV/CVC field's value is never read into any outgoing
/// message, in either direction -- not on submit, and the fill script
/// (AutofillCardFillScript, next commit) never writes to one either. This
/// app never stores a CSC and never fills one; the user always types it
/// themselves. See PasswordDetectionScript's own doc comment for the
/// broader threat-model note (page JS can already read any filled field's
/// value -- that's inherent to how forms work, not something this feature
/// introduces).
enum PaymentAddressDetectionScript {
    static let source = """
    (function() {
      if (window.__brwAutofillWatcher) { return; }
      window.__brwAutofillWatcher = true;

      function send(payload) {
        try {
          window.cefQuery({
            request: JSON.stringify(payload),
            onSuccess: function() {},
            onFailure: function() {}
          });
        } catch (e) {}
      }

      // Mirrors AutofillCore/Sources/AutofillCore/FieldClassifier.swift's
      // classify(autocomplete:name:id:placeholder:) -- see that file for
      // the canonical, unit-tested version of these exact rules.
      var AUTOCOMPLETE_TOKENS = {
        'cc-number': 'ccNumber',
        'cc-name': 'ccName',
        'cc-given-name': 'ccName',
        'cc-additional-name': 'ccName',
        'cc-family-name': 'ccName',
        'cc-exp': 'ccExpCombined',
        'cc-exp-month': 'ccExpMonth',
        'cc-exp-year': 'ccExpYear',
        'cc-csc': 'ccCSC',
        'street-address': 'streetAddress',
        'address-line1': 'streetAddress',
        'address-line2': 'addressLine2',
        'address-level1': 'addressLevel1',
        'address-level2': 'addressLevel2',
        'postal-code': 'postalCode',
        'country': 'country',
        'country-name': 'country',
        'tel': 'tel',
        'tel-national': 'tel',
        'email': 'email',
        'given-name': 'givenName',
        'family-name': 'familyName',
        'name': 'fullName'
      };

      function classify(el) {
        var autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
        if (autocomplete) {
          var tokens = autocomplete.split(' ');
          for (var i = 0; i < tokens.length; i++) {
            if (AUTOCOMPLETE_TOKENS[tokens[i]]) { return AUTOCOMPLETE_TOKENS[tokens[i]]; }
          }
        }
        var haystack = ((el.getAttribute('name') || '') + ' ' + (el.getAttribute('id') || '') + ' ' +
          (el.getAttribute('placeholder') || '')).toLowerCase();
        if (!haystack.trim()) { return null; }
        return classifyByHeuristic(haystack);
      }

      function classifyByHeuristic(haystack) {
        var compact = haystack.replace(/[^a-z0-9]/g, '');
        function has() {
          for (var i = 0; i < arguments.length; i++) {
            if (compact.indexOf(arguments[i]) !== -1) { return true; }
          }
          return false;
        }
        var tokens = haystack.split(/[^a-z0-9]+/).filter(function(t) { return t.length > 0; });
        function hasToken(t) { return tokens.indexOf(t) !== -1; }

        if (has('cvv', 'cvc', 'csc', 'securitycode', 'cardverification')) { return 'ccCSC'; }
        if (has('cardnumber', 'ccnum') || (has('card') && has('number'))) { return 'ccNumber'; }
        if (has('nameoncard', 'cardholder') || (has('card') && has('name'))) { return 'ccName'; }
        if (has('expmonth', 'expirymonth')) { return 'ccExpMonth'; }
        if (has('expyear', 'expiryyear')) { return 'ccExpYear'; }
        if (has('expiry', 'expdate', 'cardexp', 'ccexp', 'mmyy')) { return 'ccExpCombined'; }

        if (has('email')) { return 'email'; }
        if (has('phone', 'mobile', 'cellphone', 'telephone')) { return 'tel'; }
        if (has('country')) { return 'country'; }

        if (has('address2', 'addr2', 'apt', 'suite', 'unit')) { return 'addressLine2'; }
        if (has('city', 'town')) { return 'addressLevel2'; }
        if (has('state', 'province', 'region')) { return 'addressLevel1'; }
        if (has('zip', 'postal')) { return 'postalCode'; }
        if (has('street', 'address1', 'addr1', 'address')) { return 'streetAddress'; }

        if (has('firstname', 'givenname') || hasToken('fname')) { return 'givenName'; }
        if (has('lastname', 'surname', 'familyname') || hasToken('lname')) { return 'familyName'; }
        if (has('fullname') || compact === 'name') { return 'fullName'; }
        return null;
      }

      var CARD_KINDS = { ccNumber: 1, ccName: 1, ccExpMonth: 1, ccExpYear: 1, ccExpCombined: 1, ccCSC: 1 };
      var ADDRESS_KINDS = { streetAddress: 1, addressLine2: 1, addressLevel1: 1, addressLevel2: 1, postalCode: 1, country: 1 };

      // Which group (card/address) a <form> (or the whole document, for
      // fields with no enclosing form) belongs to -- an ambiguous field
      // kind (email/tel/name) doesn't decide this on its own; there must
      // be at least one unambiguous card- or address-specific field
      // present too.
      function groupForScope(scope) {
        var inputs = scope.querySelectorAll('input, select');
        var sawCard = false, sawAddress = false;
        for (var i = 0; i < inputs.length; i++) {
          var kind = classify(inputs[i]);
          if (CARD_KINDS[kind]) { sawCard = true; }
          if (ADDRESS_KINDS[kind]) { sawAddress = true; }
        }
        if (sawCard) { return 'card'; }
        if (sawAddress) { return 'address'; }
        return null;
      }

      function valueFor(scope, kind) {
        var inputs = scope.querySelectorAll('input, select');
        for (var i = 0; i < inputs.length; i++) {
          if (classify(inputs[i]) === kind) { return inputs[i].value || ''; }
        }
        return '';
      }

      // Exposed for AutofillFillScript (a later, separate executeJavaScript
      // call triggered by clicking the native fill icon) to reuse, rather
      // than porting this same classification logic a third time. Safe to
      // rely on these existing by the time a fill click can happen: this
      // detection script always runs first, at document-start, well before
      // any user interaction that could trigger a fill.
      window.__brwAutofillClassify = classify;
      window.__brwAutofillGroupForScope = groupForScope;
      window.__brwAutofillValueFor = valueFor;
      // The most recent recognized form (or `document`, for a recognized
      // field with no enclosing <form>) the user focused into -- read by
      // AutofillFillScript to know where to fill, since by the time its
      // native-button click actually runs, DOM focus may already have
      // moved off the page entirely (to the native button itself), so
      // `document.activeElement` alone can't be trusted at fill time.
      window.__brwAutofillLastScope = null;

      var lastReportedGroup = null;
      function handleFocusIn(event) {
        var el = event.target;
        if (!el || !classify(el)) { return; }
        var scope = el.form || document;
        var group = groupForScope(scope);
        if (!group) { return; }
        window.__brwAutofillLastScope = scope;
        if (group === lastReportedGroup) { return; }
        lastReportedGroup = group;
        send({ type: 'autofillFieldFocused', origin: location.origin, group: group });
      }

      function handleFocusOut(event) {
        // Only report a blur once focus has actually left every recognized
        // field -- setTimeout(0) lets the *new* focus target's own
        // focusin (if any) run first, so tabbing between two fields in the
        // same recognized form doesn't flicker the icon off and on.
        setTimeout(function() {
          var active = document.activeElement;
          if (active && classify(active)) { return; }
          if (lastReportedGroup === null) { return; }
          lastReportedGroup = null;
          send({ type: 'autofillFieldBlurred', origin: location.origin });
        }, 0);
      }

      function handleSubmit(event) {
        var scope = event.target;
        if (!scope || typeof scope.querySelectorAll !== 'function') { return; }
        var group = groupForScope(scope);
        if (group === 'card') {
          var cardNumber = valueFor(scope, 'ccNumber');
          if (!cardNumber) { return; }
          send({
            type: 'paymentFormSubmit',
            origin: location.origin,
            cardNumber: cardNumber,
            cardholderName: valueFor(scope, 'ccName'),
            expMonth: valueFor(scope, 'ccExpMonth'),
            expYear: valueFor(scope, 'ccExpYear'),
            expCombined: valueFor(scope, 'ccExpCombined')
            // Deliberately no CSC field read here at all -- see this
            // script's own doc comment.
          });
        } else if (group === 'address') {
          send({
            type: 'addressFormSubmit',
            origin: location.origin,
            fullName: valueFor(scope, 'fullName') || (valueFor(scope, 'givenName') + ' ' + valueFor(scope, 'familyName')).trim(),
            streetAddress: valueFor(scope, 'streetAddress'),
            addressLine2: valueFor(scope, 'addressLine2'),
            city: valueFor(scope, 'addressLevel2'),
            state: valueFor(scope, 'addressLevel1'),
            postalCode: valueFor(scope, 'postalCode'),
            country: valueFor(scope, 'country'),
            phone: valueFor(scope, 'tel'),
            email: valueFor(scope, 'email')
          });
        }
      }

      document.addEventListener('focusin', handleFocusIn, true);
      document.addEventListener('focusout', handleFocusOut, true);
      document.addEventListener('submit', handleSubmit, true);
    })();
    """
}
