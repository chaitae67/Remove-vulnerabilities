// 관리자 목록 표에서 행을 클릭하면 상세 화면으로 이동한다.
// 각 행에는 링크(a)도 함께 두어 키보드 이동이 가능하도록 한다.
document.addEventListener('click', function (event) {
    var row = event.target.closest('tr[data-href]');
    if (!row) {
        return;
    }
    if (event.target.closest('a, button, input, select, textarea, label, form')) {
        return;
    }
    window.location.href = row.getAttribute('data-href');
});
