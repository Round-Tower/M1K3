/* "Send it to my Mac": a phone (or any non-Mac) can't install M1K3, so this button hands
   the Mac App Store link to the share sheet: AirDrop it to the Mac, or Messages, Mail or
   Reminders to yourself. Only a title and the URL are shared, so AirDrop opens the link on
   the Mac instead of saving a note. With no share sheet it copies the link. This page sends
   nothing anywhere; the visitor picks where the link goes, or nowhere.

   The <html data-platform> that shows the button is set in each page's <head>.

   Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8. Prior: Unknown (new file).
   Review: Kev + claude-opus-5.5, 2026-10-11 — the shared link carries ct=send-to-mac, so App Store
   Connect counts the installs this button starts. Confidence 0.85. */
(function () {
  var data = { title: 'M1K3 for Mac', url: 'https://apps.apple.com/app/id6780230835?pt=120784482&ct=send-to-mac&mt=12' };
  document.querySelectorAll('[data-send-to-mac]').forEach(function (btn) {
    var label = btn.textContent;
    btn.setAttribute('aria-live', 'polite');  // so "Link copied ✓" is announced, not just drawn
    btn.addEventListener('click', function () {
      if (navigator.share) {
        navigator.share(data).catch(function () {});
      } else if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(data.url).then(function () {
          btn.textContent = 'Link copied ✓';
          setTimeout(function () { btn.textContent = label; }, 2200);
        }).catch(function () { window.prompt('Copy this link:', data.url); });
      } else {
        window.prompt('Copy this link:', data.url);
      }
    });
  });
})();
