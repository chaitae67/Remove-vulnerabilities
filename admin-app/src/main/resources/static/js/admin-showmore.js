// 관리자 목록 표: 처음 10행만 보이고 "전체보기"로 나머지를 펼친다.
document.addEventListener('DOMContentLoaded', function () {
    var LIMIT = 10;
    document.querySelectorAll('table.admin-table, table.admin-user-table').forEach(function (table) {
        var body = table.tBodies[0];
        if (!body) {
            return;
        }
        var rows = Array.prototype.slice.call(body.rows);
        if (rows.length <= LIMIT) {
            return;
        }
        rows.forEach(function (row, i) {
            if (i >= LIMIT) {
                row.hidden = true;
            }
        });

        var button = document.createElement('button');
        button.type = 'button';
        button.className = 'button button-outline admin-showmore';
        var collapsedLabel = '전체보기 (' + rows.length + '개)';
        button.textContent = collapsedLabel;
        button.addEventListener('click', function () {
            var expanded = button.getAttribute('data-expanded') === '1';
            rows.forEach(function (row, i) {
                if (i >= LIMIT) {
                    row.hidden = expanded;
                }
            });
            button.setAttribute('data-expanded', expanded ? '0' : '1');
            button.textContent = expanded ? collapsedLabel : '접기';
        });

        var wrap = table.closest('.admin-table-wrap, .admin-user-table-wrap') || table;
        wrap.parentNode.insertBefore(button, wrap.nextSibling);
    });
});
