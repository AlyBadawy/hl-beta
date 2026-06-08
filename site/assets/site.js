/* homelab.badawy — interactions (vanilla, no framework) */
(function () {
  'use strict';

  /* ---- copy-to-clipboard on code blocks ---- */
  document.querySelectorAll('.copy-btn').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var code = btn.closest('.code').querySelector('pre');
      var text = code ? code.innerText : '';
      navigator.clipboard && navigator.clipboard.writeText(text).then(function () {
        var prev = btn.textContent;
        btn.textContent = 'copied ✓';
        btn.classList.add('done');
        setTimeout(function () { btn.textContent = prev; btn.classList.remove('done'); }, 1400);
      });
    });
  });

  /* ---- mobile sidebar / nav toggle ---- */
  var toggle = document.querySelector('.nav-toggle');
  var sidebar = document.querySelector('.sidebar');
  if (toggle) {
    toggle.addEventListener('click', function () {
      if (sidebar) {
        sidebar.classList.toggle('open');
      } else {
        document.querySelector('.topnav') && document.querySelector('.topnav').classList.toggle('open');
      }
    });
  }
  if (sidebar) {
    sidebar.addEventListener('click', function (e) {
      if (e.target.tagName === 'A' && window.innerWidth < 1080) sidebar.classList.remove('open');
    });
  }

  /* ---- collapsible sidebar groups ---- */
  document.querySelectorAll('.nav-group > .nav-grouphead').forEach(function (head) {
    head.addEventListener('click', function () {
      head.parentElement.classList.toggle('collapsed');
    });
  });

  /* ---- TOC scroll-spy ---- */
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll('.toc a'));
  if (tocLinks.length) {
    var targets = tocLinks.map(function (a) {
      var el = document.getElementById(a.getAttribute('href').slice(1));
      return { a: a, el: el };
    }).filter(function (t) { return t.el; });

    var spy = function () {
      var pos = window.scrollY + 110;
      var current = targets[0];
      for (var i = 0; i < targets.length; i++) {
        if (targets[i].el.offsetTop <= pos) current = targets[i];
      }
      tocLinks.forEach(function (a) { a.classList.remove('active'); });
      if (current) current.a.classList.add('active');
    };
    window.addEventListener('scroll', spy, { passive: true });
    spy();
  }

  /* ---- reading progress bar ---- */
  var bar = document.querySelector('.read-bar i');
  if (bar) {
    var article = document.querySelector('.doc-article');
    window.addEventListener('scroll', function () {
      if (!article) return;
      var total = article.offsetHeight - window.innerHeight + 200;
      var p = Math.min(1, Math.max(0, window.scrollY / total));
      bar.style.transform = 'scaleX(' + p + ')';
    }, { passive: true });
  }

  /* ---- tabbed code examples ---- */
  document.querySelectorAll('.tabs').forEach(function (tabs) {
    var btns = tabs.querySelectorAll('.tab-btn');
    var panes = tabs.querySelectorAll('.tab-pane');
    btns.forEach(function (b, i) {
      b.addEventListener('click', function () {
        btns.forEach(function (x) { x.classList.remove('active'); });
        panes.forEach(function (x) { x.classList.remove('active'); });
        b.classList.add('active');
        panes[i] && panes[i].classList.add('active');
      });
    });
  });
})();
