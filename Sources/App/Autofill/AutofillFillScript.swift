import Foundation

/// Builds the one-shot fill scripts for card/address autofill
/// (browser-ojh.2) -- executed only in direct response to a click on the
/// native fill icon (PaymentAddressAutofillCoordinator), same
/// no-automatic-fill discipline as AutofillScript (the password manager's
/// own fill script) and for the same reason: silently filling a field
/// without a user gesture is a clickjacking/leak risk.
///
/// Relies on window.__brwAutofillClassify/__brwAutofillLastScope, both set
/// up by PaymentAddressDetectionScript (which always runs first, at
/// document-start) -- rather than re-implementing field classification a
/// third time.
enum AutofillFillScript {
    /// Fills every recognized card field it can find within the
    /// last-focused form -- cardholder name, number, and expiry (either a
    /// combined "MM/YY"-shaped field or separate month/year fields,
    /// whichever the form actually has). Deliberately never touches a CSC/
    /// CVV field, even to clear or focus it -- the user always types that
    /// themselves. `expMonth`/`expYear` are two-digit strings (already
    /// formatted by the caller); `combinedExpiry` is what's written into a
    /// single combined expiry field, if the form has one instead of
    /// separate fields.
    static func fillCardScript(cardholderName: String, cardNumber: String, expMonth: String, expYear: String, combinedExpiry: String) -> String {
        """
        (function(cardholderName, cardNumber, expMonth, expYear, combinedExpiry) {
          var scope = window.__brwAutofillLastScope || document;
          var classify = window.__brwAutofillClassify;
          if (!classify) { return; }

          function setValue(el, value) {
            if (!el || !value) { return; }
            el.value = value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }

          var inputs = scope.querySelectorAll('input, select');
          for (var i = 0; i < inputs.length; i++) {
            var kind = classify(inputs[i]);
            // Deliberately no case for 'ccCSC' at all -- see this script's
            // own doc comment.
            if (kind === 'ccName') { setValue(inputs[i], cardholderName); }
            else if (kind === 'ccNumber') { setValue(inputs[i], cardNumber); }
            else if (kind === 'ccExpMonth') { setValue(inputs[i], expMonth); }
            else if (kind === 'ccExpYear') { setValue(inputs[i], expYear); }
            else if (kind === 'ccExpCombined') { setValue(inputs[i], combinedExpiry); }
          }
        })(\(jsonStringLiteral(cardholderName)), \(jsonStringLiteral(cardNumber)), \(jsonStringLiteral(expMonth)), \(jsonStringLiteral(expYear)), \(jsonStringLiteral(combinedExpiry)));
        """
    }

    static func fillAddressScript(
        fullName: String, streetAddress: String, addressLine2: String, city: String,
        state: String, postalCode: String, country: String, phone: String, email: String
    ) -> String {
        """
        (function(fullName, streetAddress, addressLine2, city, state, postalCode, country, phone, email) {
          var scope = window.__brwAutofillLastScope || document;
          var classify = window.__brwAutofillClassify;
          if (!classify) { return; }

          function setValue(el, value) {
            if (!el || !value) { return; }
            el.value = value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }

          var values = {
            fullName: fullName, streetAddress: streetAddress, addressLine2: addressLine2,
            addressLevel2: city, addressLevel1: state, postalCode: postalCode,
            country: country, tel: phone, email: email
          };
          var inputs = scope.querySelectorAll('input, select');
          for (var i = 0; i < inputs.length; i++) {
            var kind = classify(inputs[i]);
            if (values.hasOwnProperty(kind)) { setValue(inputs[i], values[kind]); }
          }
        })(\(jsonStringLiteral(fullName)), \(jsonStringLiteral(streetAddress)), \(jsonStringLiteral(addressLine2)), \(jsonStringLiteral(city)), \(jsonStringLiteral(state)), \(jsonStringLiteral(postalCode)), \(jsonStringLiteral(country)), \(jsonStringLiteral(phone)), \(jsonStringLiteral(email)));
        """
    }

    /// Fills every recognized field in the last-focused form from
    /// `values`, keyed by the detection script's field kinds (`fullName`,
    /// `givenName`, `email`, `organization`, ...). Used for the contact
    /// card, which carries more than a saved address does. Does nothing
    /// unless it runs in the top frame of a document at `expectedOrigin`,
    /// the same guard AutofillScript uses: the card is only ever written
    /// into the page the user chose it on.
    static func fillFieldsScript(values: [String: String], expectedOrigin: WebOrigin) -> String {
        let valuesJSON = (try? JSONEncoder().encode(values)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function(values, expectedOrigin) {
          if (window.top !== window || location.origin !== expectedOrigin) { return; }
          var scope = window.__brwAutofillLastScope || document;
          var classify = window.__brwAutofillClassify;
          if (!classify) { return; }
          var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          function setValue(el, value) {
            if (!el || !value) { return; }
            if (el.tagName === 'INPUT') { setter.call(el, value); } else { el.value = value; }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          var inputs = scope.querySelectorAll('input, select');
          for (var i = 0; i < inputs.length; i++) {
            var kind = classify(inputs[i]);
            if (kind && Object.prototype.hasOwnProperty.call(values, kind)) { setValue(inputs[i], values[kind]); }
          }
        })(\(valuesJSON), \(jsonStringLiteral(expectedOrigin.serialized)));
        """
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }
}
